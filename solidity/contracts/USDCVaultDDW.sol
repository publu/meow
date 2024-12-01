// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from '../interfaces/IERC20.sol';

contract USDCVaultDDW {
  uint256 public constant MAX_INT =
    115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935;
  address public constant MAI_ADDRESS = 0xbf1aeA8670D2528E08334083616dD9C5F3B087aE;
  address public constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

  uint256 public totalStableLiquidity;
  uint256 public totalQueuedLiquidity;
  uint256 public depositFee;
  uint256 public withdrawalFee;
  uint256 public minimumDepositFee;
  uint256 public minimumWithdrawalFee;

  uint256 public maxDeposit;
  uint256 public maxWithdraw;
  uint256 public upgradeTime;

  address public owner;

  // user deposits stable, schedules withdrawal
  mapping(address => uint256) public withdrawalEpoch;
  mapping(address => uint256) public scheduledWithdrawalAmount;

  mapping(bytes4 => bool) public paused;
  bool public stopped;

  bool public initialized;

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

  // Events
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

  modifier onlyOwner() {
    if (msg.sender != owner) revert CallerIsNotOwner();
    _;
  }

  modifier pausable() {
    if (paused[msg.sig] || stopped && block.timestamp > upgradeTime) revert ContractIsPaused();
    _;
  }

  function initialize(uint256 _depositFee, uint256 _withdrawalFee) external onlyOwner {
    if (initialized) {
      revert AlreadyInitialized();
    }
    depositFee = _depositFee; // basis points
    withdrawalFee = _withdrawalFee; // basis points
    minimumDepositFee = 1_000_000; // this is 1 USDC
    minimumWithdrawalFee = 1_000_000; // 1 USDC

    maxDeposit = 1e12; // 1 million USDC (6 decimals)
    maxWithdraw = 1e12; // 1 million USDC (6 decimals)
    initialized = true;
  }

  function deposit(uint256 _amount) external pausable {
    if (_amount <= minimumDepositFee || _amount > maxDeposit) revert InvalidAmount();
    IERC20(USDC_ADDRESS).transferFrom(msg.sender, address(this), _amount);
    uint256 _fee = calculateFee(_amount, true);
    _amount = _amount - _fee;
    totalStableLiquidity += _amount;

    if (IERC20(MAI_ADDRESS).balanceOf(address(this)) < _amount * 1e12) {
      // Convert from USDC (6) to MAI (18) decimals
      revert InsufficientMAIBalance();
    }
    IERC20(MAI_ADDRESS).transfer(msg.sender, _amount * 1e12); // Convert from USDC (6) to MAI (18) decimals
    emit Deposited(msg.sender, _amount);
  }

  function scheduleWithdraw(uint256 _amount) external pausable {
    if (withdrawalEpoch[msg.sender] != 0) {
      revert WithdrawalAlreadyScheduled();
    }

    uint256 _toWithdraw = _amount / 1e12; // Convert from MAI (18) to USDC (6) decimals

    if (_amount < minimumWithdrawalFee * 1e12 || _amount > maxWithdraw * 1e12) revert InvalidAmount();
    if ((totalStableLiquidity - totalQueuedLiquidity) < _toWithdraw) revert NotEnoughLiquidity();
    totalQueuedLiquidity += _toWithdraw;
    scheduledWithdrawalAmount[msg.sender] = _amount;

    IERC20(MAI_ADDRESS).transferFrom(msg.sender, address(this), _amount);

    withdrawalEpoch[msg.sender] = block.timestamp + 3 days;
    emit WithdrawalScheduled(msg.sender, _amount);
  }

  function withdraw() external pausable {
    if (withdrawalEpoch[msg.sender] == 0 || block.timestamp < withdrawalEpoch[msg.sender]) {
      revert WithdrawalNotAvailable();
    }

    withdrawalEpoch[msg.sender] = 0;
    uint256 _amount = scheduledWithdrawalAmount[msg.sender];
    scheduledWithdrawalAmount[msg.sender] = 0;
    uint256 _toWithdraw = _amount / 1e12; // Convert from MAI (18) to USDC (6) decimals
    uint256 _fee = calculateFee(_toWithdraw, false);
    uint256 _toWithdrawwFee = (_toWithdraw - _fee);

    if (_toWithdraw > totalStableLiquidity) {
      revert NotEnoughLiquidity();
    }

    totalStableLiquidity -= _toWithdraw;
    totalQueuedLiquidity -= _toWithdraw;

    IERC20(USDC_ADDRESS).transfer(msg.sender, _toWithdrawwFee);

    emit Withdrawn(msg.sender, _amount);
  }

  function calculateFee(uint256 _amount, bool _deposit) public view returns (uint256 _fee) {
    if (_deposit) {
      _fee = _amount * depositFee / 10_000;
      _fee = _fee < minimumDepositFee ? minimumDepositFee : _fee;
    } else {
      _fee = _amount * withdrawalFee / 10_000;
      _fee = _fee < minimumWithdrawalFee ? minimumWithdrawalFee : _fee;
    }
  }

  function claimFees() external onlyOwner {
    uint256 balance = IERC20(USDC_ADDRESS).balanceOf(address(this));
    if (balance > totalStableLiquidity) {
      uint256 _fees = balance - totalStableLiquidity;
      IERC20(USDC_ADDRESS).transfer(msg.sender, _fees);
      emit FeesWithdrawn(msg.sender, _fees);
    }
  }

  function setPaused(bytes4 _selector, bool _paused) external onlyOwner {
    paused[_selector] = _paused;
    emit PauseEvent(msg.sender, _selector, _paused);
  }

  function transferOwnership(address _newOwner) external onlyOwner {
    if (_newOwner == address(0)) revert NewOwnerCannotBeZeroAddress();
    owner = _newOwner;
    emit OwnerUpdated(_newOwner);
  }

  function setUpgrade() external onlyOwner {
    if (!stopped) {
      stopped = true;
      upgradeTime = block.timestamp + 2 days;
    }
  }

  function transferToken(address _token, address _to, uint256 _amount) external onlyOwner {
    if (_token != USDC_ADDRESS || (stopped && block.timestamp > upgradeTime)) {
      IERC20(_token).transfer(_to, _amount);
    } else {
      revert UpgradeNotScheduled();
    }
  }

  function withdrawMAI() external onlyOwner {
    IERC20 _mai = IERC20(MAI_ADDRESS);
    _mai.transfer(msg.sender, _mai.balanceOf(address(this)));
  }

  function updateMinimumFees(uint256 _newMinimumDepositFee, uint256 _newMinimumWithdrawalFee) external onlyOwner {
    minimumDepositFee = _newMinimumDepositFee;
    minimumWithdrawalFee = _newMinimumWithdrawalFee;
    emit MinimumFeesUpdated(_newMinimumDepositFee, _newMinimumWithdrawalFee);
  }

  function updateFeesBP(uint256 _newDepositFee, uint256 _newWithdrawalFee) external onlyOwner {
    depositFee = _newDepositFee;
    withdrawalFee = _newWithdrawalFee;
    emit FeesUpdated(_newDepositFee, _newWithdrawalFee);
  }

  function updateMax(uint256 _maxDeposit, uint256 _maxWithdraw) external onlyOwner {
    maxDeposit = _maxDeposit;
    maxWithdraw = _maxWithdraw;
    emit MaxUpdated(_maxDeposit, _maxWithdraw);
  }
}
