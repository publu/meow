// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IBeefy} from '../interfaces/IBeefy.sol';
import {IERC20} from '../interfaces/IERC20.sol';

contract BeefyVaultPSM {
  uint256 public constant MAX_INT =
    115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935;
  address public constant MAI_ADDRESS = 0xbf1aeA8670D2528E08334083616dD9C5F3B087aE;

  uint256 public totalStableLiquidity;
  uint256 public totalQueuedLiquidity;
  uint256 public depositFee;
  uint256 public withdrawalFee;
  uint256 public minimumDepositFee;
  uint256 public minimumWithdrawalFee;
  uint256 public decimalDifference;

  uint256 public maxDeposit;
  uint256 public maxWithdraw;
  uint256 public upgradeTime;

  address public underlying;
  address public owner;
  address public gem;

  // user deposits stable, schedules withdrawal of shares
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

  // target 0x9c4ec768c28520b50860ea7a15bd7213a9ff58bf
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

  function initialize(address _gem, uint256 _depositFee, uint256 _withdrawalFee) external onlyOwner {
    if (initialized) {
      revert AlreadyInitialized();
    }
    depositFee = _depositFee; // basis points
    withdrawalFee = _withdrawalFee; // basis points
    minimumDepositFee = 1_000_000; // this is 1 dollar
    minimumWithdrawalFee = 1_000_000; // 1 dollar

    IBeefy _beef = IBeefy(_gem);

    maxDeposit = 1e24; // 1 million ether
    maxWithdraw = 1e24; // 1 million ether
    underlying = _beef.want();
    decimalDifference = uint256(_beef.decimals() - IERC20(underlying).decimals());
    gem = _gem;
    initialized = true;
    approveBeef();
  }

  function approveBeef() public {
    IERC20(underlying).approve(gem, MAX_INT);
  }

  // user deposits tokens (6 decimals), withdraws stable 18 decimals
  function deposit(uint256 _amount) external pausable {
    if (_amount <= minimumDepositFee || _amount > maxDeposit) revert InvalidAmount();
    IERC20(underlying).transferFrom(msg.sender, address(this), _amount);
    uint256 _fee = calculateFee(_amount, true);
    _amount = _amount - _fee;
    totalStableLiquidity += _amount;
    IBeefy(gem).depositAll();

    if (IERC20(MAI_ADDRESS).balanceOf(address(this)) < _amount * (10 ** (decimalDifference))) {
      revert InsufficientMAIBalance();
    }
    IERC20(MAI_ADDRESS).transfer(msg.sender, _amount * (10 ** (decimalDifference)));
    emit Deposited(msg.sender, _amount);
  }

  function scheduleWithdraw(uint256 _amount) external pausable {
    if (withdrawalEpoch[msg.sender] != 0) {
      revert WithdrawalAlreadyScheduled();
    }

    uint256 _toWithdraw = _amount / (10 ** decimalDifference);

    if (_amount < minimumWithdrawalFee || _amount > maxWithdraw) revert InvalidAmount();
    if ((totalStableLiquidity - totalQueuedLiquidity) < _toWithdraw) revert NotEnoughLiquidity();
    totalQueuedLiquidity += _toWithdraw;
    scheduledWithdrawalAmount[msg.sender] = _amount;

    IERC20(MAI_ADDRESS).transferFrom(msg.sender, address(this), _amount);

    withdrawalEpoch[msg.sender] = block.timestamp + 3 days;
    emit WithdrawalScheduled(msg.sender, _amount);
  }

  function _calculateAmountToShares(uint256 _amount) internal view returns (uint256 _shares) {
    IBeefy _beef = IBeefy(gem);
    return (_amount * _beef.totalSupply()) / _beef.balance();
  }

  function _calculateSharesToAmount(uint256 _shares) internal view returns (uint256 _amount) {
    IBeefy _beef = IBeefy(gem);
    return (_shares * _beef.balance()) / _beef.totalSupply();
  }

  function withdraw() external pausable {
    if (withdrawalEpoch[msg.sender] == 0 || block.timestamp < withdrawalEpoch[msg.sender]) {
      revert WithdrawalNotAvailable();
    }

    withdrawalEpoch[msg.sender] = 0;
    uint256 _amount = scheduledWithdrawalAmount[msg.sender];
    scheduledWithdrawalAmount[msg.sender] = 0;
    uint256 _toWithdraw = _amount / (10 ** decimalDifference);
    uint256 _fee = calculateFee(_toWithdraw, false);
    uint256 _toWithdrawwFee = (_toWithdraw - _fee);
    if (_toWithdraw > totalStableLiquidity) {
      revert NotEnoughLiquidity();
    }
    IBeefy _beef = IBeefy(gem);
    // get shares from an amount
    uint256 _freshShares = _calculateAmountToShares(_amount);
    uint256 _freshSharesRounded = (_freshShares / (10 ** decimalDifference));

    _beef.withdraw(_freshSharesRounded);

    totalStableLiquidity -= _toWithdraw;
    totalQueuedLiquidity -= _toWithdraw;

    IERC20(underlying).transfer(msg.sender, _toWithdrawwFee);
    _beef.depositAll();

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
    IBeefy _beef = IBeefy(gem);
    // get total balance in underlying
    uint256 _shares = _beef.balanceOf(address(this));
    uint256 _totalStoredInUsd = _calculateSharesToAmount(_shares);
    uint256 _totalStableShares = _calculateAmountToShares(totalStableLiquidity);
    if (_totalStoredInUsd > totalStableLiquidity) {
      uint256 _fees = (_totalStoredInUsd - totalStableLiquidity); // in USDC
      _beef.withdraw(_shares - _totalStableShares);
      emit FeesWithdrawn(msg.sender, _fees);
      IERC20 usdc = IERC20(underlying);
      usdc.transfer(msg.sender, usdc.balanceOf(address(this)));
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
    if (_token != gem || (stopped && block.timestamp > upgradeTime)) {
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
