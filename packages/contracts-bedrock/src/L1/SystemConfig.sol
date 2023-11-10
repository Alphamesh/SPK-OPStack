// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ISemver } from "src/universal/ISemver.sol";
import { ResourceMetering } from "src/L1/ResourceMetering.sol";
import { Types } from "src/libraries/Types.sol";
import { Hashing } from "src/libraries/Hashing.sol";
import { Storage } from "src/libraries/Storage.sol";
import { SuperchainConfig } from "src/L1/SuperchainConfig.sol";
import { Constants } from "src/libraries/Constants.sol";

/// @custom:audit none This contracts is not yet audited.
/// @title SystemConfig
/// @notice The SystemConfig contract is used to manage configuration of an OP Chain.
///         All configuration is stored on L1 and picked up by L2 as part of the derivation of
///         the L2 chain.
///         The values in this contract are set by the ChainGovernor.
contract SystemConfig is OwnableUpgradeable, ISemver {
    /// @notice Enum representing different types of updates.
    /// @custom:value BATCHER              Represents an update to the batcher hash.
    /// @custom:value GAS_CONFIG           Represents an update to txn fee config on L2.
    /// @custom:value GAS_LIMIT            Represents an update to gas limit on L2.
    /// @custom:value UNSAFE_BLOCK_SIGNER  Represents an update to the signer key for unsafe
    ///                                    block distrubution.
    enum UpdateType {
        BATCHER,
        GAS_CONFIG,
        GAS_LIMIT,
        UNSAFE_BLOCK_SIGNER
    }

    /// @notice Struct representing the addresses of L1 system contracts. These should be the
    ///         proxies and will differ for each OP Stack chain.
    struct Addresses {
        address l1CrossDomainMessenger;
        address l1ERC721Bridge;
        address l1StandardBridge;
        address l2OutputOracle;
        address optimismPortal;
        address optimismMintableERC20Factory;
    }

    /// @notice Struct representing the overhead, and scalar.
    struct GasConfig {
        uint256 overhead;
        uint256 scalar;
    }

    /// @notice Struct representing the Oracle Roles.
    struct OracleRoles {
        address proposer;
        address challenger;
    }

    /// @notice Version identifier, used for upgrades.
    uint256 public constant VERSION = 0;

    /// @notice Storage slot that the unsafe block signer is stored at.
    ///         Storing it at this deterministic storage slot allows for decoupling the storage
    ///         layout from the way that `solc` lays out storage. The `op-node` uses a storage
    ///         proof to fetch this value.
    /// @dev    NOTE: this value will be migrated to another storage slot in a future version.
    ///         User input should not be placed in storage in this contract until this migration
    ///         happens. It is unlikely that keccak second preimage resistance will be broken,
    ///         but it is better to be safe than sorry.
    bytes32 public constant UNSAFE_BLOCK_SIGNER_SLOT = keccak256("systemconfig.unsafeblocksigner");

    /// @notice Storage slot that the L1CrossDomainMessenger address is stored at.
    bytes32 public constant L1_CROSS_DOMAIN_MESSENGER_SLOT =
        bytes32(uint256(keccak256("systemconfig.l1crossdomainmessenger")) - 1);

    /// @notice Storage slot that the L1ERC721Bridge address is stored at.
    bytes32 public constant L1_ERC_721_BRIDGE_SLOT = bytes32(uint256(keccak256("systemconfig.l1erc721bridge")) - 1);

    /// @notice Storage slot that the L1StandardBridge address is stored at.
    bytes32 public constant L1_STANDARD_BRIDGE_SLOT = bytes32(uint256(keccak256("systemconfig.l1standardbridge")) - 1);

    /// @notice Storage slot that the L2OutputOracle address is stored at.
    bytes32 public constant L2_OUTPUT_ORACLE_SLOT = bytes32(uint256(keccak256("systemconfig.l2outputoracle")) - 1);

    /// @notice Storage slot that the OptimismPortal address is stored at.
    bytes32 public constant OPTIMISM_PORTAL_SLOT = bytes32(uint256(keccak256("systemconfig.optimismportal")) - 1);

    /// @notice Storage slot that the OptimismMintableERC20Factory address is stored at.
    bytes32 public constant OPTIMISM_MINTABLE_ERC20_FACTORY_SLOT =
        bytes32(uint256(keccak256("systemconfig.optimismmintableerc20factory")) - 1);

    /// @notice Storage slot that the batch inbox address is stored at.
    bytes32 public constant BATCH_INBOX_SLOT = bytes32(uint256(keccak256("systemconfig.batchinbox")) - 1);

    /// @notice Storage slot that the SuperchainConfig address is stored at.
    bytes32 public constant SUPERCHAIN_CONFIG_SLOT = bytes32(uint256(keccak256("systemconfig.superchainconfig")) - 1);

    /// @notice Fixed L2 gas overhead. Used as part of the L2 fee calculation.
    uint256 public overhead;

    /// @notice Dynamic L2 gas overhead. Used as part of the L2 fee calculation.
    uint256 public scalar;

    /// @notice Identifier for the batcher.
    ///         For version 1 of this configuration, this is represented as an address left-padded
    ///         with zeros to 32 bytes.
    bytes32 public batcherHash;

    /// @notice L2 block gas limit.
    uint64 public gasLimit;

    /// @notice The configuration for the deposit fee market.
    ///         Used by the OptimismPortal to meter the cost of buying L2 gas on L1.
    ///         Set as internal with a getter so that the struct is returned instead of a tuple.
    ResourceMetering.ResourceConfig internal _resourceConfig;

    /// @notice The block at which the op-node can start searching for logs from.
    uint256 public startBlock;

    /// @notice Proposer address, proposes new outputs.
    address public proposer;

    /// @notice Challenger address, can delete outputs.
    address public challenger;

    /// @notice Semantic version.
    /// @custom:semver 2.0.0
    string public constant version = "2.0.0";

    /// @notice Emitted when configuration is updated.
    /// @param version    SystemConfig version.
    /// @param updateType Type of update.
    /// @param data       Encoded update data.
    event ConfigUpdate(uint256 indexed version, UpdateType indexed updateType, bytes data);

    /// @notice Emitted when the proposer is updated.
    /// @param newProposer The address of the new proposer.
    event ProposerUpdated(address indexed newProposer);

    /// @notice Emitted when the challenger is updated.
    /// @param newChallenger The address of the new challenger.
    event ChallengerUpdated(address indexed newChallenger);

    /// @notice Constructs the SystemConfig contract. Cannot set
    ///         the owner to `address(0)` due to the Ownable contract's
    ///         implementation, so set it to `address(0xdEaD)`
    constructor() {
        initialize({
            _owner: address(0xdEaD),
            _superchainConfig: address(0),
            _gasConfig: GasConfig({ overhead: 0, scalar: 0 }),
            _batcherHash: bytes32(0),
            _gasLimit: 1,
            _unsafeBlockSigner: address(0),
            _config: ResourceMetering.ResourceConfig({
                maxResourceLimit: 1,
                elasticityMultiplier: 1,
                baseFeeMaxChangeDenominator: 2,
                minimumBaseFee: 0,
                systemTxMaxGas: 0,
                maximumBaseFee: 0
            }),
            _startBlock: type(uint256).max,
            _batchInbox: address(0),
            _oracleRoles: OracleRoles({ proposer: address(0), challenger: address(0) }),
            _addresses: Addresses({
                l1CrossDomainMessenger: address(0),
                l1ERC721Bridge: address(0),
                l1StandardBridge: address(0),
                l2OutputOracle: address(0),
                optimismPortal: address(0),
                optimismMintableERC20Factory: address(0)
            })
        });
    }

    /// @notice Initializer.
    ///         The resource config must be set before the require check.
    /// @param _owner             Initial owner of the contract.
    /// @param _superchainConfig  Initial superchainConfig address.
    /// @param _gasConfig         Initial gas config (overhead and scalar) values.
    /// @param _batcherHash       Initial batcher hash.
    /// @param _gasLimit          Initial gas limit.
    /// @param _unsafeBlockSigner Initial unsafe block signer address.
    /// @param _config            Initial ResourceConfig.
    /// @param _startBlock        Starting block for the op-node to search for logs from.
    ///                           Contracts that were deployed before this field existed
    ///                           need to have this field set manually via an override.
    ///                           Newly deployed contracts should set this value to uint256(0).
    /// @param _oracleRoles       Initial proposer and challenger addresses.
    /// @param _batchInbox        Batch inbox address. An identifier for the op-node to find
    ///                           canonical data.
    /// @param _addresses         Set of L1 contract addresses. These should be the proxies.
    function initialize(
        address _owner,
        address _superchainConfig,
        GasConfig memory _gasConfig,
        bytes32 _batcherHash,
        uint64 _gasLimit,
        address _unsafeBlockSigner,
        ResourceMetering.ResourceConfig memory _config,
        uint256 _startBlock,
        address _batchInbox,
        OracleRoles memory _oracleRoles,
        SystemConfig.Addresses memory _addresses
    )
        public
        reinitializer(Constants.INITIALIZER)
    {
        __Ownable_init();
        transferOwnership(_owner);

        // These are set in ascending order of their UpdateTypes.
        _setBatcherHash(_batcherHash);
        _setGasConfig(_gasConfig);
        _setGasLimit(_gasLimit);
        _setUnsafeBlockSigner(_unsafeBlockSigner);
        _setProposer(_oracleRoles.proposer);
        _setChallenger(_oracleRoles.challenger);

        Storage.setAddress(BATCH_INBOX_SLOT, _batchInbox);
        Storage.setAddress(L1_CROSS_DOMAIN_MESSENGER_SLOT, _addresses.l1CrossDomainMessenger);
        Storage.setAddress(L1_ERC_721_BRIDGE_SLOT, _addresses.l1ERC721Bridge);
        Storage.setAddress(L1_STANDARD_BRIDGE_SLOT, _addresses.l1StandardBridge);
        Storage.setAddress(L2_OUTPUT_ORACLE_SLOT, _addresses.l2OutputOracle);
        Storage.setAddress(OPTIMISM_PORTAL_SLOT, _addresses.optimismPortal);
        Storage.setAddress(OPTIMISM_MINTABLE_ERC20_FACTORY_SLOT, _addresses.optimismMintableERC20Factory);
        Storage.setAddress(SUPERCHAIN_CONFIG_SLOT, _superchainConfig);

        _setStartBlock(_startBlock);

        _setResourceConfig(_config);
        require(_gasLimit >= minimumGasLimit(), "SystemConfig: gas limit too low");
    }

    /// @notice Returns the minimum L2 gas limit that can be safely set for the system to
    ///         operate. The L2 gas limit must be larger than or equal to the amount of
    ///         gas that is allocated for deposits per block plus the amount of gas that
    ///         is allocated for the system transaction.
    ///         This function is used to determine if changes to parameters are safe.
    /// @return minGasLimit_ uint64 Minimum gas limit.
    function minimumGasLimit() public view returns (uint64 minGasLimit_) {
        minGasLimit_ = uint64(_resourceConfig.maxResourceLimit) + uint64(_resourceConfig.systemTxMaxGas);
    }

    /// @notice High level getter for the unsafe block signer address.
    ///         Unsafe blocks can be propagated across the p2p network if they are signed by the
    ///         key corresponding to this address.
    /// @return addr_ Address of the unsafe block signer.
    // solhint-disable-next-line ordering
    function unsafeBlockSigner() public view returns (address addr_) {
        addr_ = Storage.getAddress(UNSAFE_BLOCK_SIGNER_SLOT);
    }

    /// @notice Getter for the SuperChainConfig address.
    function superchainConfig() public view returns (address addr_) {
        addr_ = Storage.getAddress(SUPERCHAIN_CONFIG_SLOT);
    }

    /// @notice Getter for the L1CrossDomainMessenger address.
    function l1CrossDomainMessenger() external view returns (address addr_) {
        addr_ = Storage.getAddress(L1_CROSS_DOMAIN_MESSENGER_SLOT);
    }

    /// @notice Getter for the L1ERC721Bridge address.
    function l1ERC721Bridge() external view returns (address addr_) {
        addr_ = Storage.getAddress(L1_ERC_721_BRIDGE_SLOT);
    }

    /// @notice Getter for the L1StandardBridge address.
    function l1StandardBridge() external view returns (address addr_) {
        addr_ = Storage.getAddress(L1_STANDARD_BRIDGE_SLOT);
    }

    /// @notice Getter for the L2OutputOracle address.
    function l2OutputOracle() external view returns (address addr_) {
        addr_ = Storage.getAddress(L2_OUTPUT_ORACLE_SLOT);
    }

    /// @notice Getter for the OptimismPortal address.
    function optimismPortal() external view returns (address addr_) {
        addr_ = Storage.getAddress(OPTIMISM_PORTAL_SLOT);
    }

    /// @notice Getter for the OptimismMintableERC20Factory address.
    function optimismMintableERC20Factory() external view returns (address addr_) {
        addr_ = Storage.getAddress(OPTIMISM_MINTABLE_ERC20_FACTORY_SLOT);
    }

    /// @notice Getter for the BatchInbox address.
    function batchInbox() external view returns (address addr_) {
        addr_ = Storage.getAddress(BATCH_INBOX_SLOT);
    }

    /// @notice Sets the start block in a backwards compatible way. Proxies
    ///         that were initialized before the startBlock existed in storage
    ///         can have their start block set by a user provided override.
    ///         A start block of 0 indicates that there is no override and the
    ///         start block will be set by `block.number`.
    /// @dev    This logic is used to patch legacy deployments with new storage values.
    ///         Use the override if it is provided as a non zero value and the value
    ///         has not already been set in storage. Use `block.number` if the value
    ///         has already been set in storage
    /// @param  _startBlock The start block override to set in storage.
    function _setStartBlock(uint256 _startBlock) internal {
        if (_startBlock != 0 && startBlock == 0) {
            // There is an override and it is not already set, this is for legacy chains.
            startBlock = _startBlock;
        } else if (startBlock == 0) {
            // There is no override and it is not set in storage. Set it to the block number.
            // This is for newly deployed chains.
            startBlock = block.number;
        }
    }

    /// @notice Updates the unsafe block signer address. Can only be called by the owner.
    /// @param _batcherHash New batch hash.
    /// @param _unsafeBlockSigner New unsafe block signer address.
    function setSequencer(bytes32 _batcherHash, address _unsafeBlockSigner) external onlyOwner {
        _setUnsafeBlockSigner(_unsafeBlockSigner);
        _setBatcherHash(_batcherHash);

        Types.SequencerKeyPair memory _sequencer =
            Types.SequencerKeyPair({ unsafeBlockSigner: _unsafeBlockSigner, batcherHash: _batcherHash });
        bytes32 seqHash = Hashing.hashSequencerKeyPair(_sequencer);
        require(
            SuperchainConfig(superchainConfig()).allowedSequencers(seqHash),
            "SystemConfig: Sequencer hash not found in Superchain allow list"
        );
    }

    /// @notice Checks the SuperchainConfig's allow list for the current sequencer. If it is not allowed,
    ///         the sequencer is removed. Anyone may call this function.
    function checkSequencer() external {
        Types.SequencerKeyPair memory sequencer =
            Types.SequencerKeyPair({ unsafeBlockSigner: unsafeBlockSigner(), batcherHash: batcherHash });
        bytes32 seqHash = Hashing.hashSequencerKeyPair(sequencer);
        if (SuperchainConfig(superchainConfig()).allowedSequencers(seqHash)) {
            revert("SystemConfig: cannot remove allowed sequencer.");
        }
        _setUnsafeBlockSigner(address(0));
        _setBatcherHash(bytes32(0));
    }

    /// @notice Updates the unsafe block signer address.
    /// @param _unsafeBlockSigner New unsafe block signer address.
    function _setUnsafeBlockSigner(address _unsafeBlockSigner) internal {
        Storage.setAddress(UNSAFE_BLOCK_SIGNER_SLOT, _unsafeBlockSigner);

        bytes memory data = abi.encode(_unsafeBlockSigner);
        emit ConfigUpdate(VERSION, UpdateType.UNSAFE_BLOCK_SIGNER, data);
    }

    /// @notice Internal function for updating the batcher hash.
    /// @param _batcherHash New batcher hash.
    function _setBatcherHash(bytes32 _batcherHash) internal {
        batcherHash = _batcherHash;

        bytes memory data = abi.encode(_batcherHash);
        emit ConfigUpdate(VERSION, UpdateType.BATCHER, data);
    }

    /// @notice Updates gas config. Can only be called by the owner.
    /// @param _gasConfig New gas config.
    function setGasConfig(GasConfig memory _gasConfig) external onlyOwner {
        _setGasConfig(_gasConfig);
    }

    /// @notice Internal function for updating the gas config.
    /// @param _gasConfig New gas config.
    function _setGasConfig(GasConfig memory _gasConfig) internal {
        overhead = _gasConfig.overhead;
        scalar = _gasConfig.scalar;

        bytes memory data = abi.encode(_gasConfig.overhead, _gasConfig.scalar);
        emit ConfigUpdate(VERSION, UpdateType.GAS_CONFIG, data);
    }

    /// @notice Updates the L2 gas limit. Can only be called by the owner.
    /// @param _gasLimit New gas limit.
    function setGasLimit(uint64 _gasLimit) external onlyOwner {
        _setGasLimit(_gasLimit);
    }

    /// @notice Internal function for updating the L2 gas limit.
    /// @param _gasLimit New gas limit.
    function _setGasLimit(uint64 _gasLimit) internal {
        require(_gasLimit >= minimumGasLimit(), "SystemConfig: gas limit too low");
        gasLimit = _gasLimit;

        bytes memory data = abi.encode(_gasLimit);
        emit ConfigUpdate(VERSION, UpdateType.GAS_LIMIT, data);
    }

    /// @notice A getter for the resource config.
    ///         Ensures that the struct is returned instead of a tuple.
    /// @return ResourceConfig
    function resourceConfig() external view returns (ResourceMetering.ResourceConfig memory) {
        return _resourceConfig;
    }

    /// @notice An external setter for the resource config.
    ///         In the future, this method may emit an event that the `op-node` picks up
    ///         for when the resource config is changed.
    /// @param _config The new resource config values.
    function setResourceConfig(ResourceMetering.ResourceConfig memory _config) external onlyOwner {
        _setResourceConfig(_config);
    }

    /// @notice An internal setter for the resource config.
    ///         Ensures that the config is sane before storing it by checking for invariants.
    /// @param _config The new resource config.
    function _setResourceConfig(ResourceMetering.ResourceConfig memory _config) internal {
        // Min base fee must be less than or equal to max base fee.
        require(
            _config.minimumBaseFee <= _config.maximumBaseFee, "SystemConfig: min base fee must be less than max base"
        );
        // Base fee change denominator must be greater than 1.
        require(_config.baseFeeMaxChangeDenominator > 1, "SystemConfig: denominator must be larger than 1");
        // Max resource limit plus system tx gas must be less than or equal to the L2 gas limit.
        // The gas limit must be increased before these values can be increased.
        require(_config.maxResourceLimit + _config.systemTxMaxGas <= gasLimit, "SystemConfig: gas limit too low");
        // Elasticity multiplier must be greater than 0.
        require(_config.elasticityMultiplier > 0, "SystemConfig: elasticity multiplier cannot be 0");
        // No precision loss when computing target resource limit.
        require(
            ((_config.maxResourceLimit / _config.elasticityMultiplier) * _config.elasticityMultiplier)
                == _config.maxResourceLimit,
            "SystemConfig: precision loss with target resource limit"
        );

        _resourceConfig = _config;
    }

    /// @notice Checks if the given address is a proposal manager. The same entities who can delete an output
    ///         should also be able to update the proposer; because in the event that a faulty output is proposed,
    ///         the malicious proposer will need to be removed prior to deleting the output.
    /// @param _manager The address to check.
    /// @return isManager_ A boolean indicating if the address is a proposal manager.
    function isProposalManager(address _manager) public view returns (bool isManager_) {
        SuperchainConfig _superchainConfig = SuperchainConfig(superchainConfig());
        isManager_ = _manager == challenger || _manager == _superchainConfig.initiator()
            || _manager == _superchainConfig.vetoer();
    }

    /// @notice Updates the proposer. Can only be a proposal manager (owner, initiator or vetoer).
    /// @param _proposer New proposer address.
    function setProposer(address _proposer) external {
        require(isProposalManager(msg.sender), "SystemConfig: caller is not authorized to update the proposer");
        _setProposer(_proposer);
    }

    /// @notice Internal function for updating the proposer.
    /// @param _proposer New proposer.
    function _setProposer(address _proposer) internal {
        proposer = _proposer;
        emit ProposerUpdated(_proposer);
    }

    /// @notice Updates the challenger. Can only be called by the owner.
    /// @param _challenger New challenger address.
    function setChallenger(address _challenger) external onlyOwner {
        _setChallenger(_challenger);
    }

    /// @notice Internal function for updating the challenger.
    /// @param _challenger New challenger.
    function _setChallenger(address _challenger) internal {
        challenger = _challenger;
        emit ChallengerUpdated(_challenger);
    }
}
