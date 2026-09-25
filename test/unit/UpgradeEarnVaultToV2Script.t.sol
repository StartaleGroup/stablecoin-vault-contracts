// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnVaultV2UpgradeChecks} from '../../script/upgrade/EarnVaultV2UpgradeChecks.sol';
import {UpgradeEarnVaultToV2} from '../../script/upgrade/UpgradeEarnVaultToV2.s.sol';
import {VerifyEarnVaultV2Upgrade} from '../../script/upgrade/VerifyEarnVaultV2Upgrade.s.sol';
import {EarnVaultUpgradeable} from '../../src/vaults/earn/EarnVaultUpgradeable.sol';
import {EarnVaultV2} from '../../src/vaults/earn/EarnVaultV2.sol';
import {MockUSDSC} from '../mocks/MockUSDSC.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Test} from 'lib/forge-std/src/Test.sol';

/// @notice Drives the V2 upgrade script and the live-verify script against a real local V1 proxy.
///         The upgrade script contract itself owns the ProxyAdmin here (in production the broadcaster
///         key does), so its ProxyAdmin call is authorized.
contract UpgradeEarnVaultToV2ScriptTest is Test {
  UpgradeEarnVaultToV2 internal script;
  VerifyEarnVaultV2Upgrade internal verifier;
  MockUSDSC internal usdsc;
  address internal proxy;
  address internal pa;

  address internal owner = makeAddr('owner');
  address internal treasury = makeAddr('treasury');
  address internal redistributor = makeAddr('redistributor');
  address internal pauser = makeAddr('pauser');
  address internal operator = makeAddr('operator'); // V1's boostRewardKeeper
  address internal keeper = makeAddr('boostKeeper');
  uint256 internal constant CAP = 5000e6;
  bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1);
  bytes32 internal constant IMPL_SLOT = bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1);

  function _v1InitData() internal view returns (bytes memory) {
    return abi.encodeWithSelector(
      EarnVaultUpgradeable.initialize.selector, address(usdsc), owner, redistributor, treasury, pauser, operator
    );
  }

  function _params(address impl) internal view returns (UpgradeEarnVaultToV2.Params memory) {
    return
      UpgradeEarnVaultToV2.Params({proxy: proxy, expectedAdmin: pa, keeper: keeper, cap: CAP, implementation: impl});
  }

  function _roles() internal view returns (EarnVaultV2UpgradeChecks.Roles memory) {
    return EarnVaultV2UpgradeChecks.Roles({
      owner: owner, treasury: treasury, yieldRedistributor: redistributor, pauser: pauser, boostRewardKeeper: operator
    });
  }

  function setUp() public {
    script = new UpgradeEarnVaultToV2();
    verifier = new VerifyEarnVaultV2Upgrade();
    usdsc = new MockUSDSC();
    proxy =
      address(new TransparentUpgradeableProxy(address(new EarnVaultUpgradeable()), address(script), _v1InitData()));
    pa = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));

    // real V1 state that must survive the upgrade untouched
    address depositor = makeAddr('depositor');
    usdsc.mint(depositor, 700e6);
    vm.startPrank(depositor);
    usdsc.approve(proxy, 700e6);
    EarnVaultUpgradeable(payable(proxy)).deposit(700e6);
    vm.stopPrank();
  }

  function test_Upgrade_HappyPath_FreshImplementation_InitializesV2AndPreservesV1State() public {
    uint256 principalBefore = EarnVaultUpgradeable(payable(proxy)).principal(makeAddr('depositor'));
    address impl = script.upgrade(_params(address(0)), address(script));

    EarnVaultV2 v2 = EarnVaultV2(payable(proxy));
    assertEq(v2.getVersion(), 'EarnVaultV2');
    assertEq(v2.boostKeeper(), keeper);
    assertEq(v2.maxBoostPerBatch(), CAP);
    assertEq(v2.principal(makeAddr('depositor')), principalBefore);
    assertEq(address(uint160(uint256(vm.load(proxy, IMPL_SLOT)))), impl);
  }

  /// @dev IMPLEMENTATION path: upgrades to the given, pre-deployed (explorer-verified) address
  ///      rather than deploying new bytecode.
  function test_Upgrade_UsesPreDeployedImplementation() public {
    address preDeployed = address(new EarnVaultV2());
    address impl = script.upgrade(_params(preDeployed), address(script));
    assertEq(impl, preDeployed);
    assertEq(address(uint160(uint256(vm.load(proxy, IMPL_SLOT)))), preDeployed);
  }

  function test_Preflight_RejectsImplementationThatIsNotV2() public {
    address notV2 = address(new EarnVaultUpgradeable());
    vm.expectRevert(bytes('IMPLEMENTATION is not EarnVaultV2'));
    script.upgrade(_params(notV2), address(script));
    vm.expectRevert(bytes('IMPLEMENTATION has no code'));
    script.upgrade(_params(makeAddr('eoa')), address(script));
  }

  function test_Preflight_RevertsOnUnexpectedAdmin() public {
    UpgradeEarnVaultToV2.Params memory p = _params(address(0));
    p.expectedAdmin = makeAddr('someOtherProxyAdmin');
    vm.expectRevert(bytes('ERC-1967 admin slot != EXPECTED_PROXY_ADMIN'));
    script.upgrade(p, address(script));
  }

  /// @dev A proxy with no ERC-1967 admin (UUPS shape) is refused before anything is sent.
  function test_Preflight_RevertsOnProxyWithoutAdmin() public {
    UpgradeEarnVaultToV2.Params memory p = _params(address(0));
    p.proxy = address(new ERC1967Proxy(address(new EarnVaultUpgradeable()), _v1InitData()));
    vm.expectRevert(bytes('ERC-1967 admin slot != EXPECTED_PROXY_ADMIN'));
    script.upgrade(p, address(script));
  }

  function test_Preflight_RevertsWhenSenderDoesNotOwnProxyAdmin() public {
    vm.expectRevert(bytes('sender does not own the ProxyAdmin'));
    script.upgrade(_params(address(0)), makeAddr('notTheOwner'));
  }

  function test_Preflight_RevertsOnZeroKeeperOrCap() public {
    UpgradeEarnVaultToV2.Params memory p = _params(address(0));
    p.keeper = address(0);
    vm.expectRevert(bytes('BOOST_KEEPER_ADDRESS not set'));
    script.upgrade(p, address(script));
    p = _params(address(0));
    p.cap = 0;
    vm.expectRevert(bytes('MAX_BOOST_PER_BATCH must be non-zero'));
    script.upgrade(p, address(script));
  }

  function test_Preflight_RevertsWhenAlreadyOnV2() public {
    script.upgrade(_params(address(0)), address(script));
    vm.expectRevert(bytes('proxy is not on EarnVaultV1'));
    script.upgrade(_params(address(0)), address(script));
  }

  function test_Preflight_DoesNotChangeState_AndSnapshotsRoles() public {
    UpgradeEarnVaultToV2.V1Snapshot memory snap = script.preflight(_params(address(0)), address(script));
    assertEq(EarnVaultUpgradeable(payable(proxy)).getVersion(), 'EarnVaultV1');
    assertEq(ProxyAdmin(pa).owner(), address(script));
    assertEq(snap.roles.owner, owner);
    assertEq(snap.roles.treasury, treasury);
    assertEq(snap.roles.yieldRedistributor, redistributor);
    assertEq(snap.roles.pauser, pauser);
    assertEq(snap.roles.boostRewardKeeper, operator, 'boostRewardKeeper read from its storage slot');
  }

  /// @dev The live-verify script passes on a correctly upgraded proxy, and fails on any mismatch in
  ///      config or roles.
  function test_Verify_PassesAfterUpgrade_FailsOnMismatch() public {
    address impl = script.upgrade(_params(address(0)), address(script));
    verifier.verify(proxy, pa, impl, keeper, CAP, _roles());

    vm.expectRevert(bytes('implementation slot mismatch'));
    verifier.verify(proxy, pa, makeAddr('wrongImpl'), keeper, CAP, _roles());
    vm.expectRevert(bytes('maxBoostPerBatch mismatch'));
    verifier.verify(proxy, pa, impl, keeper, CAP + 1, _roles());

    EarnVaultV2UpgradeChecks.Roles memory wrong = _roles();
    wrong.pauser = makeAddr('wrongPauser');
    vm.expectRevert(bytes('pauser mismatch'));
    verifier.verify(proxy, pa, impl, keeper, CAP, wrong);
  }

  /// @dev Before the upgrade, verification must fail (the proxy is still V1).
  function test_Verify_FailsBeforeUpgrade() public {
    address v1Impl = address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    vm.expectRevert(bytes('version is not EarnVaultV2'));
    verifier.verify(proxy, pa, v1Impl, keeper, CAP, _roles());
  }
}
