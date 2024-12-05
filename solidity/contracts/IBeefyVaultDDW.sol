// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IBeefyVaultDelayWithdrawal {
  // Public variables
  function MAX_INT() external view returns (uint256);
  function MAI_ADDRESS() external view returns (address);
  function totalStableLiquidity() external view returns (uint256);
  function depositFee() external view returns (uint256);
  function withdrawalFee() external view returns (uint256);
  function minimumDepositFee() external view returns (uint256);
  function minimumWithdrawalFee() external view returns (uint256);
  function decimalDifference() external view returns (uint256);
  function maxDeposit() external view returns (uint256);
  function maxWithdraw() external view returns (uint256);
  function underlying() external view returns (address);
  function owner() external view returns (address);
  function gem() external view returns (address);
  function withdrawalEpoch(address _user) external view returns (uint256);
  function scheduledWithdrawalAmount(address _user) external view returns (uint256);
  function paused() external view returns (bool);
  function initialized() external view returns (bool);

  // Functions
  function approveBeef() external;
  function deposit(uint256 _amount) external;
  function scheduleWithdraw(uint256 _amount) external;
  function withdraw() external;
  function calculateFee(uint256 _amount, bool _deposit) external view returns (uint256);
  function claimFees() external;
  function togglePause(bool _paused) external;
  function transferOwnership(address _newOwner) external;
}
