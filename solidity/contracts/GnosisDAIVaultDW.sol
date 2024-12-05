// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from '../interfaces/IERC20.sol';
import {IL2DSR} from '../interfaces/IL2DSR.sol';

contract GnosisDAIVaultPSM {
  uint256 public constant MAX_INT =
    115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935;

  address public constant MAI_ADDRESS = 0x3F56e0c36d275367b8C502090EDF38289b3dEa0d;

  address public constant WXDAI_ADDRESS = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

  uint256 public totalStableLiquidity;
  uint256 public totalQueuedLiquidity;
  uint256 public depositFee;
  uint256 public withdrawalFee;
  uint256 public minimumDepositFee;
  uint256 public minimumWithdrawalFee;

  uint256 public maxDeposit;
  uint256 public maxWithdraw;
  uint256 public upgradeTime;

  address public underlying; // xDai/wxDai
  address public owner;
  address public gem; // sDai vault address

  // Rest of the state variables remain the same...
  mapping(address => uint256) public withdrawalEpoch;
  mapping(address => uint256) public scheduledWithdrawalAmount;
  mapping(bytes4 => bool) public paused;
  bool public stopped;
  bool public initialized;

  // Keep existing errors...
  error CallerIsNotOwner();
  error ContractIsPaused();
  error InvalidAmount();
  error InvalidAmountAfterFee();
  error InsufficientMAIBalance();
  error WithdrawalAlreadyScheduled();
  error NotWithinWithdrawalPeriod();
  error NoWithdrawalScheduled();
  error WithdrawalAlreadyExecutable();
  error AlreadyInitialized();
  error NewOwnerCannotBeZeroAddress();
  error WithdrawalNotAvailable();
  error NotEnoughLiquidity();
  error UpgradeNotScheduled();

  // Keep existing events...
  event Deposited(address indexed _user, uint256 _amount);
  event Withdrawn(address indexed _user, uint256 _amount);
  event OwnerUpdated(address _newOwner);
  event MAIRemoved(address indexed _user, uint256 _amount);
  event FeesWithdrawn(address indexed _owner, uint256 _feesEarned);
  event PauseEvent(address _account, bytes4 _selector, bool _paused);
  event WithdrawalCancelled(address indexed _user, uint256 _amount);
  event ScheduledWithdrawal(address indexed _user, uint256 _amount);
  event WithdrawalScheduled(address indexed _user, uint256 _amount);
  event MaxDepositUpdated(uint256 _maxDeposit);
  event MaxWithdrawUpdated(uint256 _maxWithdraw);
  event MinimumFeesUpdated(uint256 _newMinimumDepositFee, uint256 _newMinimumWithdrawalFee);
  event FeesUpdated(uint256 _newDepositFee, uint256 _newWithdrawalFee);
  event MaxUpdated(uint256 _maxDeposit, uint256 _maxWithdraw);

  constructor() {
    owner = msg.sender;
  }

  // Keep existing modifiers...
  modifier onlyOwner() {
    if (msg.sender != owner) revert CallerIsNotOwner();
    _;
  }

  modifier pausable() {
    if (paused[msg.sig] || (stopped && block.timestamp > upgradeTime)) revert ContractIsPaused();
    _;
  }

  receive() external payable {}

  function initialize(address _gem, uint256 _depositFee, uint256 _withdrawalFee) external onlyOwner {
    if (initialized) {
      revert AlreadyInitialized();
    }
    depositFee = _depositFee;
    withdrawalFee = _withdrawalFee;
    minimumDepositFee = 1 ether;
    minimumWithdrawalFee = 1 ether;

    IL2DSR _sdai = IL2DSR(_gem);

    maxDeposit = 1e24; // 1 million ether
    maxWithdraw = 1e24; // 1 million ether
    underlying = _sdai.asset();
    gem = _gem;
    initialized = true;
    approveGem();
  }

  function approveGem() public {
    IERC20(WXDAI_ADDRESS).approve(gem, MAX_INT);
  }

  function deposit(uint256 _amount) external payable pausable {
    if (_amount <= minimumDepositFee || _amount > maxDeposit) revert InvalidAmount();

    // Handle native xDai deposits
    if (msg.value > 0) {
      require(msg.value == _amount, 'Invalid xDai amount');
      // Wrap xDai to wxDai
      (bool success,) = WXDAI_ADDRESS.call{value: msg.value}('');
      require(success, 'Failed to wrap xDai');
    } else {
      // Transfer wxDai directly
      IERC20(WXDAI_ADDRESS).transferFrom(msg.sender, address(this), _amount);
    }

    uint256 _fee = calculateFee(_amount, true);
    uint256 _amountAfterFee = _amount - _fee;

    // Deposit wxDai into sDai vault
    IL2DSR(gem).deposit(_amountAfterFee, address(this));

    totalStableLiquidity += _amountAfterFee;

    if (IERC20(MAI_ADDRESS).balanceOf(address(this)) < _amountAfterFee) {
      revert InsufficientMAIBalance();
    }
    IERC20(MAI_ADDRESS).transfer(msg.sender, _amountAfterFee);
    emit Deposited(msg.sender, _amountAfterFee);
  }

  // Modified withdraw function to handle native xDai
  function withdraw() external pausable {
    if (withdrawalEpoch[msg.sender] == 0 || block.timestamp < withdrawalEpoch[msg.sender]) {
      revert WithdrawalNotAvailable();
    }

    withdrawalEpoch[msg.sender] = 0;
    uint256 _amount = scheduledWithdrawalAmount[msg.sender];
    scheduledWithdrawalAmount[msg.sender] = 0;

    uint256 _fee = calculateFee(_amount, false);
    uint256 _amountAfterFee = _amount - _fee;

    if (_amount > totalStableLiquidity) {
      revert NotEnoughLiquidity();
    }

    totalStableLiquidity -= _amount;
    totalQueuedLiquidity -= _amount;

    // Withdraw from sDai vault to get wxDai
    IL2DSR(gem).withdraw(_amountAfterFee, address(this), address(this));

    // Unwrap wxDai to native xDai and send to user
    IERC20(WXDAI_ADDRESS).transfer(msg.sender, _amountAfterFee);

    emit Withdrawn(msg.sender, _amount);
  }

  /// @notice Calculates the fee for deposit or withdrawal
  /// @param _amount The amount to calculate the fee on
  /// @param _deposit Boolean indicating if the fee is for a deposit (true) or withdrawal (false)
  /// @return _fee The calculated fee
  function calculateFee(uint256 _amount, bool _deposit) public view returns (uint256 _fee) {
    if (_deposit) {
      _fee = _amount * depositFee / 10_000;
      _fee = _fee < minimumDepositFee ? minimumDepositFee : _fee;
    } else {
      _fee = _amount * withdrawalFee / 10_000;
      _fee = _fee < minimumWithdrawalFee ? minimumWithdrawalFee : _fee;
    }
  }

  /// @notice Allows the owner to claim fees accumulated in the contract
  function claimFees() external onlyOwner {
    IL2DSR _beef = IL2DSR(gem);

    uint256 totalShares = _beef.balanceOf(address(this));
    uint256 _totalStoredInUsd = _beef.convertToAssets(totalShares);
    if (_totalStoredInUsd > totalStableLiquidity) {
      uint256 _fees = (_totalStoredInUsd - totalStableLiquidity); // in USDC
      _beef.withdraw(_totalStoredInUsd - totalStableLiquidity, msg.sender, address(this));
      emit FeesWithdrawn(msg.sender, _fees);
      // directly sends the owner the amount
    }
  }

  /// @notice Sets a function selector to paused or unpaused
  /// @param _selector The function selector to pause or unpause
  /// @param _paused Boolean indicating if the function should be paused (true) or unpaused (false)
  function setPaused(bytes4 _selector, bool _paused) external onlyOwner {
    paused[_selector] = _paused;
    emit PauseEvent(msg.sender, _selector, _paused);
  }

  /// @notice Transfers ownership of the contract to a new owner
  /// @param _newOwner The address of the new owner
  function transferOwnership(address _newOwner) external onlyOwner {
    if (_newOwner == address(0)) revert NewOwnerCannotBeZeroAddress();
    owner = _newOwner;
    emit OwnerUpdated(_newOwner);
  }

  /// @notice Prepares the contract for an upgrade
  function setUpgrade() external onlyOwner {
    if (!stopped) {
      stopped = true;
      upgradeTime = block.timestamp + 2 days;
    }
  }

  /// @notice Allows the owner to transfer tokens from the contract
  /// @param _token The address of the token to transfer
  /// @param _to The address to transfer the tokens to
  /// @param _amount The amount of tokens to transfer
  function transferToken(address _token, address _to, uint256 _amount) external onlyOwner {
    if (_token != gem || (stopped && block.timestamp > upgradeTime)) {
      IERC20(_token).transfer(_to, _amount);
    } else {
      revert UpgradeNotScheduled();
    }
  }

  /// @notice Allows the owner to withdraw MAI tokens from the contract
  function withdrawMAI() external onlyOwner {
    IERC20 _mai = IERC20(MAI_ADDRESS);
    _mai.transfer(msg.sender, _mai.balanceOf(address(this)));
  }

  /// @notice Updates the minimum fees for deposit and withdrawal
  /// @param _newMinimumDepositFee The new minimum deposit fee
  /// @param _newMinimumWithdrawalFee The new minimum withdrawal fee
  function updateMinimumFees(uint256 _newMinimumDepositFee, uint256 _newMinimumWithdrawalFee) external onlyOwner {
    minimumDepositFee = _newMinimumDepositFee;
    minimumWithdrawalFee = _newMinimumWithdrawalFee;
    emit MinimumFeesUpdated(_newMinimumDepositFee, _newMinimumWithdrawalFee);
  }

  /// @notice Updates the deposit and withdrawal fees in basis points
  /// @param _newDepositFee The new deposit fee in basis points
  /// @param _newWithdrawalFee The new withdrawal fee in basis points
  function updateFeesBP(uint256 _newDepositFee, uint256 _newWithdrawalFee) external onlyOwner {
    depositFee = _newDepositFee;
    withdrawalFee = _newWithdrawalFee;
    emit FeesUpdated(_newDepositFee, _newWithdrawalFee);
  }

  /// @notice Updates the maximum deposit and withdrawal limits
  /// @param _maxDeposit The new maximum deposit limit
  /// @param _maxWithdraw The new maximum withdrawal limit
  function updateMax(uint256 _maxDeposit, uint256 _maxWithdraw) external onlyOwner {
    maxDeposit = _maxDeposit;
    maxWithdraw = _maxWithdraw;
    emit MaxUpdated(_maxDeposit, _maxWithdraw);
  }
}
