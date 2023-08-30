// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {IBurnMintERC20} from "../../../shared/token/ERC20/IBurnMintERC20.sol";

import "../BaseTest.t.sol";
import {TokenPool} from "../../pools/TokenPool.sol";
import {Router} from "../../Router.sol";
import {USDCTokenPool} from "../../pools/USDC/USDCTokenPool.sol";
import {BurnMintERC677} from "../../../shared/token/ERC677/BurnMintERC677.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {USDCTokenPoolHelper} from "../helpers/USDCTokenPoolHelper.sol";

import {IERC165} from "../../../vendor/openzeppelin-solidity/v4.8.0/contracts/utils/introspection/IERC165.sol";

contract USDCTokenPoolSetup is BaseTest {
  IBurnMintERC20 internal s_token;
  MockUSDC internal s_mockUSDC;

  uint32 internal constant SOURCE_DOMAIN_IDENTIFIER = 0x02020202;
  uint32 internal constant DEST_DOMAIN_IDENTIFIER = 0x03030303;

  address internal s_routerAllowedOnRamp = address(3456);
  address internal s_routerAllowedOffRamp = address(234);
  Router internal s_router;

  USDCTokenPoolHelper internal s_usdcTokenPool;
  USDCTokenPoolHelper internal s_usdcTokenPoolWithAllowList;
  address[] internal s_allowedList;

  function setUp() public virtual override {
    BaseTest.setUp();
    s_token = new BurnMintERC677("LINK", "LNK", 18, 0);
    deal(address(s_token), OWNER, type(uint256).max);
    setUpRamps();

    s_mockUSDC = new MockUSDC(42);

    USDCTokenPool.USDCConfig memory config = USDCTokenPool.USDCConfig({
      version: s_mockUSDC.messageBodyVersion(),
      tokenMessenger: address(s_mockUSDC),
      messageTransmitter: address(s_mockUSDC)
    });

    s_usdcTokenPool = new USDCTokenPoolHelper(
      config,
      s_token,
      new address[](0),
      address(s_mockARM),
      DEST_DOMAIN_IDENTIFIER
    );

    s_allowedList.push(USER_1);
    s_usdcTokenPoolWithAllowList = new USDCTokenPoolHelper(
      config,
      s_token,
      s_allowedList,
      address(s_mockARM),
      DEST_DOMAIN_IDENTIFIER
    );

    TokenPool.RampUpdate[] memory onRamps = new TokenPool.RampUpdate[](1);
    onRamps[0] = TokenPool.RampUpdate({
      ramp: s_routerAllowedOnRamp,
      allowed: true,
      rateLimiterConfig: rateLimiterConfig()
    });

    TokenPool.RampUpdate[] memory offRamps = new TokenPool.RampUpdate[](1);
    offRamps[0] = TokenPool.RampUpdate({
      ramp: s_routerAllowedOffRamp,
      allowed: true,
      rateLimiterConfig: rateLimiterConfig()
    });

    s_usdcTokenPool.applyRampUpdates(onRamps, offRamps);
    s_usdcTokenPoolWithAllowList.applyRampUpdates(onRamps, offRamps);

    USDCTokenPool.DomainUpdate[] memory domains = new USDCTokenPool.DomainUpdate[](1);
    domains[0] = USDCTokenPool.DomainUpdate({
      destChainSelector: DEST_CHAIN_ID,
      domainIdentifier: 9999,
      allowedCaller: keccak256("allowedCaller"),
      enabled: true
    });

    s_usdcTokenPool.setDomains(domains);
    s_usdcTokenPoolWithAllowList.setDomains(domains);
  }

  function setUpRamps() internal {
    s_router = new Router(address(s_token), address(s_mockARM));

    Router.OnRamp[] memory onRampUpdates = new Router.OnRamp[](1);
    onRampUpdates[0] = Router.OnRamp({destChainSelector: DEST_CHAIN_ID, onRamp: s_routerAllowedOnRamp});
    Router.OffRamp[] memory offRampUpdates = new Router.OffRamp[](1);
    address[] memory offRamps = new address[](1);
    offRamps[0] = s_routerAllowedOffRamp;
    offRampUpdates[0] = Router.OffRamp({sourceChainSelector: SOURCE_CHAIN_ID, offRamp: offRamps[0]});

    s_router.applyRampUpdates(onRampUpdates, new Router.OffRamp[](0), offRampUpdates);
  }

  function _generateUSDCMessage(uint64 nonce, address sender, address recipient) internal pure returns (bytes memory) {
    uint32 version = 1;
    bytes memory body = bytes("body");

    return
      abi.encodePacked(
        version,
        SOURCE_DOMAIN_IDENTIFIER,
        DEST_DOMAIN_IDENTIFIER,
        nonce,
        bytes32(uint256(uint160(sender))),
        bytes32(uint256(uint160(recipient))),
        body
      );
  }
}

contract USDCTokenPool_lockOrBurn is USDCTokenPoolSetup {
  error SenderNotAllowed(address sender);

  event DepositForBurn(
    uint64 indexed nonce,
    address indexed burnToken,
    uint256 amount,
    address indexed depositor,
    bytes32 mintRecipient,
    uint32 destinationDomain,
    bytes32 destinationTokenMessenger,
    bytes32 destinationCaller
  );
  event Burned(address indexed sender, uint256 amount);
  event TokensConsumed(uint256 tokens);

  function testFuzz_LockOrBurnSuccess(bytes32 destinationReceiver, uint256 amount) public {
    vm.assume(amount < rateLimiterConfig().capacity);
    vm.assume(amount > 0);
    changePrank(s_routerAllowedOnRamp);
    s_token.approve(address(s_usdcTokenPool), amount);

    USDCTokenPool.Domain memory expectedDomain = s_usdcTokenPool.getDomain(DEST_CHAIN_ID);

    vm.expectEmit();
    emit TokensConsumed(amount);
    vm.expectEmit();
    emit DepositForBurn(
      s_mockUSDC.s_nonce(),
      address(s_token),
      amount,
      address(s_usdcTokenPool),
      destinationReceiver,
      expectedDomain.domainIdentifier,
      s_mockUSDC.i_destinationTokenMessenger(),
      expectedDomain.allowedCaller
    );
    vm.expectEmit();
    emit Burned(s_routerAllowedOnRamp, amount);

    bytes memory encodedNonce = s_usdcTokenPool.lockOrBurn(
      OWNER,
      abi.encodePacked(destinationReceiver),
      amount,
      DEST_CHAIN_ID,
      bytes("")
    );
    uint64 nonce = abi.decode(encodedNonce, (uint64));
    assertEq(s_mockUSDC.s_nonce() - 1, nonce);
  }

  function testFuzz_LockOrBurnWithAllowListSuccess(bytes32 destinationReceiver, uint256 amount) public {
    vm.assume(amount < rateLimiterConfig().capacity);
    vm.assume(amount > 0);
    changePrank(s_routerAllowedOnRamp);
    s_token.approve(address(s_usdcTokenPoolWithAllowList), amount);

    USDCTokenPool.Domain memory expectedDomain = s_usdcTokenPoolWithAllowList.getDomain(DEST_CHAIN_ID);

    vm.expectEmit();
    emit TokensConsumed(amount);
    vm.expectEmit();
    emit DepositForBurn(
      s_mockUSDC.s_nonce(),
      address(s_token),
      amount,
      address(s_usdcTokenPoolWithAllowList),
      destinationReceiver,
      expectedDomain.domainIdentifier,
      s_mockUSDC.i_destinationTokenMessenger(),
      expectedDomain.allowedCaller
    );
    vm.expectEmit();
    emit Burned(s_routerAllowedOnRamp, amount);

    bytes memory encodedNonce = s_usdcTokenPoolWithAllowList.lockOrBurn(
      s_allowedList[0],
      abi.encodePacked(destinationReceiver),
      amount,
      DEST_CHAIN_ID,
      bytes("")
    );
    uint64 nonce = abi.decode(encodedNonce, (uint64));
    assertEq(s_mockUSDC.s_nonce() - 1, nonce);
  }

  // Reverts
  function testUnknownDomainReverts() public {
    uint256 amount = 1000;
    changePrank(s_routerAllowedOnRamp);
    deal(address(s_token), s_routerAllowedOnRamp, amount);
    s_token.approve(address(s_usdcTokenPool), amount);

    uint64 wrongDomain = DEST_CHAIN_ID + 1;

    vm.expectRevert(abi.encodeWithSelector(USDCTokenPool.UnknownDomain.selector, wrongDomain));

    s_usdcTokenPool.lockOrBurn(OWNER, abi.encodePacked(address(0)), amount, wrongDomain, bytes(""));
  }

  function testPermissionsErrorReverts() public {
    vm.expectRevert(TokenPool.PermissionsError.selector);

    s_usdcTokenPool.lockOrBurn(OWNER, abi.encodePacked(address(0)), 0, DEST_CHAIN_ID, bytes(""));
  }

  function testLockOrBurnWithAllowListReverts() public {
    changePrank(s_routerAllowedOnRamp);

    vm.expectRevert(abi.encodeWithSelector(SenderNotAllowed.selector, STRANGER));

    s_usdcTokenPoolWithAllowList.lockOrBurn(STRANGER, abi.encodePacked(address(0)), 1000, DEST_CHAIN_ID, bytes(""));
  }
}

contract USDCTokenPool_releaseOrMint is USDCTokenPoolSetup {
  event Minted(address indexed sender, address indexed recipient, uint256 amount);

  function testFuzz_ReleaseOrMintSuccess(address receiver, uint256 amount) public {
    amount = bound(amount, 0, rateLimiterConfig().capacity);
    changePrank(s_routerAllowedOffRamp);

    uint64 nonce = 0x060606060606;
    address sender = OWNER;

    bytes memory message = _generateUSDCMessage(nonce, sender, receiver);
    bytes memory attestation = bytes("attestation bytes");

    bytes memory offchainTokenData = abi.encode(
      USDCTokenPool.MessageAndAttestation({message: message, attestation: attestation})
    );
    bytes memory sourceTokenDataPayload = abi.encode(
      USDCTokenPool.SourceTokenDataPayload({nonce: nonce, sourceDomain: SOURCE_DOMAIN_IDENTIFIER})
    );
    bytes memory extraData = abi.encode(offchainTokenData, sourceTokenDataPayload);

    vm.expectEmit();
    emit Minted(s_routerAllowedOffRamp, receiver, amount);

    vm.expectCall(address(s_mockUSDC), abi.encodeWithSelector(MockUSDC.receiveMessage.selector, message, attestation));

    s_usdcTokenPool.releaseOrMint(abi.encode(sender), receiver, amount, SOURCE_CHAIN_ID, extraData);
  }

  // Reverts
  function testUnlockingUSDCFailedReverts() public {
    changePrank(s_routerAllowedOffRamp);
    s_mockUSDC.setShouldSucceed(false);

    uint64 nonce = 0x0606060606060606;
    bytes memory message = _generateUSDCMessage(nonce, OWNER, OWNER);

    bytes memory offchainTokenData = abi.encode(
      USDCTokenPool.MessageAndAttestation({message: message, attestation: bytes("")})
    );

    bytes memory sourceTokenDataPayload = abi.encode(
      USDCTokenPool.SourceTokenDataPayload({nonce: nonce, sourceDomain: SOURCE_DOMAIN_IDENTIFIER})
    );
    bytes memory extraData = abi.encode(offchainTokenData, sourceTokenDataPayload);

    vm.expectRevert(USDCTokenPool.UnlockingUSDCFailed.selector);

    s_usdcTokenPool.releaseOrMint(abi.encode(OWNER), OWNER, 1, SOURCE_CHAIN_ID, extraData);
  }

  function testTokenMaxCapacityExceededReverts() public {
    uint256 capacity = rateLimiterConfig().capacity;
    uint256 amount = 10 * capacity;
    address receiver = address(1);
    changePrank(s_routerAllowedOffRamp);

    bytes memory extraData = abi.encode(
      USDCTokenPool.MessageAndAttestation({message: bytes(""), attestation: bytes("")})
    );

    vm.expectRevert(
      abi.encodeWithSelector(RateLimiter.TokenMaxCapacityExceeded.selector, capacity, amount, address(s_token))
    );

    s_usdcTokenPool.releaseOrMint(abi.encode(OWNER), receiver, amount, SOURCE_CHAIN_ID, extraData);
  }
}

contract USDCTokenPool_supportsInterface is USDCTokenPoolSetup {
  function testSupportsInterfaceSuccess() public {
    assertTrue(s_usdcTokenPool.supportsInterface(s_usdcTokenPool.getUSDCInterfaceId()));
    assertTrue(s_usdcTokenPool.supportsInterface(type(IPool).interfaceId));
    assertTrue(s_usdcTokenPool.supportsInterface(type(IERC165).interfaceId));
  }
}

contract USDCTokenPool_setDomains is USDCTokenPoolSetup {
  event DomainsSet(USDCTokenPool.DomainUpdate[]);

  mapping(uint64 destChainSelector => USDCTokenPool.Domain domain) private s_chainToDomain;

  // Setting lower fuzz run as 256 runs was causing differing gas results in snapshot.
  /// forge-config: default.fuzz.runs = 32
  /// forge-config: ccip.fuzz.runs = 32
  function testFuzz_SetDomainsSuccess(
    bytes32[10] calldata allowedCallers,
    uint32[10] calldata domainIdentifiers,
    uint64[10] calldata destChainSelectors
  ) public {
    uint256 numberOfDomains = allowedCallers.length;
    USDCTokenPool.DomainUpdate[] memory domainUpdates = new USDCTokenPool.DomainUpdate[](numberOfDomains);
    for (uint256 i = 0; i < numberOfDomains; ++i) {
      domainUpdates[i] = USDCTokenPool.DomainUpdate({
        allowedCaller: allowedCallers[i],
        domainIdentifier: domainIdentifiers[i],
        destChainSelector: destChainSelectors[i],
        enabled: true
      });

      s_chainToDomain[destChainSelectors[i]] = USDCTokenPool.Domain({
        domainIdentifier: domainIdentifiers[i],
        allowedCaller: allowedCallers[i],
        enabled: true
      });
    }

    vm.expectEmit();
    emit DomainsSet(domainUpdates);

    s_usdcTokenPool.setDomains(domainUpdates);

    for (uint256 i = 0; i < numberOfDomains; ++i) {
      USDCTokenPool.Domain memory expected = s_chainToDomain[destChainSelectors[i]];
      USDCTokenPool.Domain memory got = s_usdcTokenPool.getDomain(destChainSelectors[i]);
      assertEq(got.allowedCaller, expected.allowedCaller);
      assertEq(got.domainIdentifier, expected.domainIdentifier);
    }
  }

  // Reverts

  function testOnlyOwnerReverts() public {
    USDCTokenPool.DomainUpdate[] memory domainUpdates = new USDCTokenPool.DomainUpdate[](0);

    changePrank(STRANGER);
    vm.expectRevert("Only callable by owner");

    s_usdcTokenPool.setDomains(domainUpdates);
  }
}

contract USDCTokenPool_setConfig is USDCTokenPoolSetup {
  event ConfigSet(USDCTokenPool.USDCConfig);

  function testSetConfigSuccess() public {
    USDCTokenPool.USDCConfig memory newConfig = USDCTokenPool.USDCConfig({
      version: 12332,
      tokenMessenger: address(100),
      messageTransmitter: address(123456789)
    });

    USDCTokenPool.USDCConfig memory oldConfig = s_usdcTokenPool.getConfig();

    vm.expectEmit();
    emit ConfigSet(newConfig);
    s_usdcTokenPool.setConfig(newConfig);

    USDCTokenPool.USDCConfig memory gotConfig = s_usdcTokenPool.getConfig();
    assertEq(gotConfig.tokenMessenger, newConfig.tokenMessenger);
    assertEq(gotConfig.messageTransmitter, newConfig.messageTransmitter);
    assertEq(gotConfig.version, newConfig.version);

    assertEq(0, s_usdcTokenPool.getToken().allowance(address(s_usdcTokenPool), oldConfig.tokenMessenger));
    assertEq(
      type(uint256).max,
      s_usdcTokenPool.getToken().allowance(address(s_usdcTokenPool), gotConfig.tokenMessenger)
    );
  }

  // Reverts

  function testInvalidConfigReverts() public {
    USDCTokenPool.USDCConfig memory newConfig = USDCTokenPool.USDCConfig({
      version: 12332,
      tokenMessenger: address(0),
      messageTransmitter: address(123456789)
    });

    vm.expectRevert(USDCTokenPool.InvalidConfig.selector);
    s_usdcTokenPool.setConfig(newConfig);

    newConfig.tokenMessenger = address(235);
    newConfig.messageTransmitter = address(0);

    vm.expectRevert(USDCTokenPool.InvalidConfig.selector);
    s_usdcTokenPool.setConfig(newConfig);
  }

  function testOnlyOwnerReverts() public {
    changePrank(STRANGER);
    vm.expectRevert("Only callable by owner");

    s_usdcTokenPool.setConfig(
      USDCTokenPool.USDCConfig({version: 1, tokenMessenger: address(100), messageTransmitter: address(1)})
    );
  }
}

contract USDCTokenPool__validateMessage is USDCTokenPoolSetup {
  function testFuzz_ValidateMessageSuccess(uint32 sourceDomain, uint64 nonce, bytes32 sender, bytes32 receiver) public {
    vm.pauseGasMetering();
    bytes memory usdcMessage = abi.encodePacked(
      uint32(1),
      sourceDomain,
      DEST_DOMAIN_IDENTIFIER,
      nonce,
      sender,
      receiver,
      bytes("body")
    );
    vm.resumeGasMetering();
    s_usdcTokenPool.validateMessage(usdcMessage, sourceDomain, nonce, sender, receiver);
  }

  function testValidateInvalidMessageReverts() public {
    uint32 version = 1;
    uint32 sourceDomain = 1553252;
    uint32 destinationDomain = DEST_DOMAIN_IDENTIFIER;
    uint64 nonce = 387289284924;
    bytes32 sender = bytes32(uint256(8238942935223));
    bytes32 receiver = bytes32(uint256(92398429395823));

    bytes memory usdcMessage = abi.encodePacked(
      version,
      sourceDomain,
      destinationDomain,
      nonce,
      sender,
      receiver,
      bytes("")
    );

    s_usdcTokenPool.validateMessage(usdcMessage, sourceDomain, nonce, sender, receiver);

    uint32 expectedSourceDomain = sourceDomain + 1;

    vm.expectRevert(
      abi.encodeWithSelector(USDCTokenPool.InvalidSourceDomain.selector, expectedSourceDomain, sourceDomain)
    );
    s_usdcTokenPool.validateMessage(usdcMessage, expectedSourceDomain, nonce, sender, receiver);

    uint64 expectedNonce = nonce + 1;

    vm.expectRevert(abi.encodeWithSelector(USDCTokenPool.InvalidNonce.selector, expectedNonce, nonce));
    s_usdcTokenPool.validateMessage(usdcMessage, sourceDomain, expectedNonce, sender, receiver);

    bytes32 expectedSender = bytes32(uint256(888));

    vm.expectRevert(abi.encodeWithSelector(USDCTokenPool.InvalidSender.selector, expectedSender, sender));
    s_usdcTokenPool.validateMessage(usdcMessage, sourceDomain, nonce, expectedSender, receiver);

    bytes32 expectedReceiver = bytes32(uint256(111));

    vm.expectRevert(abi.encodeWithSelector(USDCTokenPool.InvalidReceiver.selector, expectedReceiver, receiver));
    s_usdcTokenPool.validateMessage(usdcMessage, sourceDomain, nonce, sender, expectedReceiver);

    uint32 wrongVersion = version + 1;

    usdcMessage = abi.encodePacked(wrongVersion, sourceDomain, destinationDomain, nonce, sender, receiver, bytes(""));

    vm.expectRevert(abi.encodeWithSelector(USDCTokenPool.InvalidMessageVersion.selector, wrongVersion));
    s_usdcTokenPool.validateMessage(usdcMessage, sourceDomain, nonce, sender, receiver);

    uint32 wrongDestinationDomain = destinationDomain + 1;

    usdcMessage = abi.encodePacked(version, sourceDomain, wrongDestinationDomain, nonce, sender, receiver, bytes(""));

    vm.expectRevert(
      abi.encodeWithSelector(USDCTokenPool.InvalidDestinationDomain.selector, destinationDomain, wrongDestinationDomain)
    );
    s_usdcTokenPool.validateMessage(usdcMessage, sourceDomain, nonce, sender, receiver);
  }
}
