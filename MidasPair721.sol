// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import {LPToken} from "./LPToken.sol";

import {Clone} from "./libraries/Clone.sol";
import {FeeHelper} from "./libraries/FeeHelper.sol";
import {Uint128x128Math} from "./libraries/Math128x128.sol";
import {Math512Bits} from "./libraries/Math512Bits.sol";
import {PackedUint128Math} from "./libraries/PackedUint128Math.sol";
import {PackedUint24Math} from "./libraries/PackedUint24Math.sol";
import {PositionHelper} from "./libraries/PositionHelper.sol";
import {ReentrancyGuardUpgradeable} from "./libraries/ReentrancyGuardUpgradeable.sol";
import {TokenHelper} from "./libraries/TokenHelper.sol";
import {TreeMath} from "./libraries/TreeMath.sol";
import {IMidasPair721} from "./interfaces/IMidasPair721.sol";
import {IMidasFactory721} from "./interfaces/IMidasFactory721.sol";
import {IMidasFlashLoanCallback} from "./interfaces/IMidasFlashLoanCallback.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

/// @title Midas Pair
/// @author midaswap
/// @notice This contract is the implementation of Liquidity Book Pair that also acts as the receipt token for liquidity positions

contract MidasPair721 is
    ERC721Holder,
    ReentrancyGuardUpgradeable,
    IMidasPair721,
    Clone
{
    error MidasPair__AddressWrong();
    error MidasPair__RangeWrong();
    error MidasPair__AmountInWrong();
    error MidasPair__BinSequenceWrong();
    error MidasPair__LengthWrong();
    error MidasPair__NFTOwnershipWrong();
    error MidasPair__PriceOverflow();
    error MidasPair__ZeroBorrowAmount();
    error MidasPair__FlashLoanCallbackFailed();

    using Math512Bits for uint256;
    using TreeMath for TreeMath.TreeUint24;
    using TokenHelper for IERC20;
    using PackedUint128Math for bytes32;
    using PackedUint24Math for bytes32;
    using PackedUint24Math for uint24;
    using FeeHelper for uint128;
    using PositionHelper for uint128[];
    using PositionHelper for uint24[];
    using Uint128x128Math for uint256;

    /// @notice The factory contract that created this pair
    IMidasFactory721 public immutable override factory;

    uint256 private constant MAX = type(uint256).max;

    bytes32 private _Reserves;
    bytes32 private _Fees;
    bytes32 private _RoyaltyInfo;
    bytes32 private _IDs;

    address payable[] private creators;
    uint256[] private creatorShares;

    TreeMath.TreeUint24 private _tree;
    TreeMath.TreeUint24 private _tree2;

    /// @dev binIds -> binReserves (reservesX , reservesY)
    mapping(uint24 => bytes32) private _bins;
    /// @dev lpTokenId -> BinParams (originID , binStep , unclaimedFee)
    mapping(uint128 => bytes32) private lpInfos;
    /// @dev lpTokenId -> NFT tokenIds
    mapping(uint128 => uint256[]) private lpTokenAssetsMap;
    /// @dev NFT tokenIds -> lpTokenId
    mapping(uint256 => uint128) private assetLPMap;
    /// @dev binIds -> lpTokenIds
    mapping(uint24 => uint128[]) private binLPMap;

    /** Constructor **/

    constructor(address _factory) {
        if (_factory == address(0)) revert MidasPair__AddressWrong();
        factory = IMidasFactory721(_factory);
    }

    function initialize() external override {
        if (address(factory) != msg.sender) revert MidasPair__AddressWrong();
        __ReentrancyGuard_init();
        _IDs = 0x0000000000000000000000000000000000000000000000000000ffffff000000;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getTokenX() external pure override returns (IERC721) {
        return tokenX();
    }

    function getTokenY() external pure override returns (IERC20) {
        return tokenY();
    }

    function getLPToken() external pure override returns (LPToken) {
        return lpToken();
    }

    function getReserves() external view override returns (uint128, uint128) {
        return _Reserves.decode();
    }

    function getIDs()
        external
        view
        override
        returns (
            uint24 bestOfferID,
            uint24 floorPriceID,
            uint128 currentPositionID
        )
    {
        return _IDs.getAll();
    }

    function getGlobalFees() external view override returns (uint128, uint128) {
        return _Fees.decode();
    }

    function feeParameters()
        external
        view
        override
        returns (uint128 rate, uint128 protocolRate, uint128 royaltyRate)
    {
        rate = _rate();
        protocolRate = 1e17;
        royaltyRate = _RoyaltyInfo.decodeX();
    }

    /// @notice View function to get the bin at `id`
    /// @param _id The bin id
    /// @return reserveX The reserve of tokenX of the bin
    /// @return reserveY The reserve of tokenY of the bin
    function getBin(
        uint24 _id
    ) external view override returns (uint128, uint128) {
        return _bins[_id].decode();
    }

    function getLpInfos(
        uint128 _LPtokenID
    ) external view override returns (uint24, uint24, uint128) {
        return lpInfos[_LPtokenID].getAll();
    }

    function getPriceFromBin(
        uint24 _id
    ) external pure override returns (uint128) {
        return _getPriceFromBin(_id);
    }

    function getLPFromNFT(
        uint256 _NFTID
    ) external view override returns (uint128) {
        return assetLPMap[_NFTID];
    }

    function getBinParamFromLP(
        uint128 _lpTokenID,
        uint256 _amount
    ) external view override returns (uint128 _totalPrice) {
        uint256[] memory _map;
        uint24 i;
        uint24 j;
        uint24 _start;
        uint24 _binStep;
        bytes32 _lpInfo;
        _map = lpTokenAssetsMap[_lpTokenID];
        _lpInfo = lpInfos[_lpTokenID];
        (_start, _binStep) = _lpInfo.getBothUint24();
        while (j < _amount) {
            if (_map[i] != MAX) {
                _totalPrice += _getPriceFromBin(_start + _binStep * i);
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function getLpReserve(
        uint128 _lpTokenID
    ) external view override returns (uint128, uint128) {
        uint256 _length;
        uint128 amountX;
        uint128 amountY;
        uint128 fee;
        uint128 _price;
        uint24 originBin;
        uint24 binStep;
        uint24 _id;
        uint256[] memory lpAsset;
        lpAsset = lpTokenAssetsMap[_lpTokenID];
        _length = lpAsset.length;
        (originBin, binStep, fee) = lpInfos[_lpTokenID].getAll();
        if (_lpTokenID & 0x1 != type(uint128).min)
            return (type(uint128).min, type(uint128).min);
        for (uint24 i; i < _length; ) {
            if (lpAsset[i] != MAX) {
                unchecked {
                    amountX += 1e18;
                }
            } else {
                unchecked {
                    _id = originBin + i * binStep;
                }
                _price = _getPriceFromBin(_id);
                unchecked {
                    amountY += _price;
                }
            }
            unchecked {
                ++i;
            }
        }
        unchecked {
            amountY += fee;
        }
        return (amountX, amountY);
    }

    /* ========== EXTERNAL FUNCTIONS ========== */

    function sellNFT(
        uint256 NFTID,
        address _to
    ) external override nonReentrant returns (uint128 _amountOut) {
        uint24 _tradeID;
        bytes32 _royaltyInfo;
        uint128 _amountOutOfBin;
        uint128 _feesTotal;
        uint128 _feesProtocol;
        uint128 _feesRoyalty;

        _tradeID = _IDs.getFirstUint24();
        _royaltyInfo = _RoyaltyInfo;
        _amountOutOfBin = _getPriceFromBin(_tradeID);
        (_feesTotal, _feesProtocol, _feesRoyalty) = _amountOutOfBin
            .getFeeBaseAndDistribution(_rate(), _royaltyInfo.decodeX());

        unchecked {
            _amountOut = _amountOutOfBin - _feesTotal - _feesRoyalty;
        }

        uint128[] memory _lps;
        uint128 _LPtokenID;
        _lps = binLPMap[_tradeID];
        _LPtokenID = _lps[0];
        binLPMap[_tradeID] = _lps._removeFirstItem();
        _checkNFTOwner(NFTID);
        assetLPMap[NFTID] = _LPtokenID;

        // update _RoyaltyInfo
        _royaltyInfo = _royaltyInfo.addSecond(_feesRoyalty);
        _RoyaltyInfo = _royaltyInfo;

        _updateAssetMapSell(_LPtokenID, _tradeID, NFTID);

        _updateLpInfo(_LPtokenID, _feesTotal - _feesProtocol);

        // update _Fees
        bytes32 _fees;
        _fees = _Fees;
        _fees = _fees.add(_feesTotal, _feesProtocol);
        _Fees = _fees;

        // update _Reserves
        bytes32 _reserves;
        _reserves = _Reserves;
        _reserves = _reserves.addFirst(1e18).subSecond(_amountOutOfBin);
        _Reserves = _reserves;

        // update _bins
        bytes32 _bin;
        _bin = _bins[_tradeID];
        _bin = _bin.addFirst(1e18).subSecond(_amountOutOfBin);
        _bins[_tradeID] = _bin;
        // update trees
        if (_bin.decodeX() == 1e18) _tree2.add(_tradeID);
        if (_bin.decodeY() == type(uint128).min) _tree.remove(_tradeID);
        // update _IDs
        _updateIDs(type(uint128).min);

        tokenY().safeTransfer(_to, _amountOut);

        emit SellNFT(NFTID, _to, _tradeID, _LPtokenID);
    }

    function buyNFT(uint256 NFTID, address _to) external override nonReentrant {
        uint128 _LPtokenID;
        uint24 _tradeId;
        bytes32 _bin;
        bytes32 _royaltyInfo;
        bytes32 _reserves;
        bytes32 _fees;
        uint128 _amountInToBin;
        uint128 _feesTotal;
        uint128 _feesProtocol;
        uint128 _feesRoyalty;

        _LPtokenID = assetLPMap[NFTID];
        _tradeId = _updateAssetMapBuy(_LPtokenID, NFTID);
        _bin = _bins[_tradeId];
        _royaltyInfo = _RoyaltyInfo;
        _reserves = _Reserves;
        _fees = _Fees;
        _amountInToBin = _getPriceFromBin(_tradeId);
        (_feesTotal, _feesProtocol, _feesRoyalty) = _amountInToBin
            .getFeeAmountDistributionWithRoyalty(
                _rate(),
                _royaltyInfo.decodeX()
            );

        delete assetLPMap[NFTID];
        tokenX().safeTransferFrom(address(this), _to, NFTID);
        if (
            _amountInToBin + _feesTotal + _feesRoyalty >
            tokenY().received(
                _reserves.decodeY(),
                _fees.decodeX(),
                _royaltyInfo.decodeY()
            )
        ) revert MidasPair__AmountInWrong();

        _royaltyInfo = _royaltyInfo.addSecond(_feesRoyalty);

        if (_LPtokenID & 0x1 == type(uint128).min) {
            // NFT from NFT LPs
            if (_bin.decodeY() == type(uint128).min) _tree.add(_tradeId);
            binLPMap[_tradeId].push(_LPtokenID);

            _updateLpInfo(_LPtokenID, _feesTotal - _feesProtocol);
            _fees = _fees.add(_feesTotal, _feesProtocol);
            _reserves = _reserves.subFirst(1e18).addSecond(_amountInToBin);
            _bin = _bin.subFirst(1e18).addSecond(_amountInToBin);
        } else {
            // NFT from Limited Orders
            _updateLpInfo(_LPtokenID, _amountInToBin);
            _fees = _fees.add(_amountInToBin + _feesTotal, _feesTotal);
            _reserves = _reserves.subFirst(1e18);
            _bin = _bin.subFirst(1e18);
        }

        //update trees
        if (_bin.decodeX() == type(uint128).min) _tree2.remove(_tradeId);

        _updateIDs(type(uint128).min);
        _bins[_tradeId] = _bin;
        _RoyaltyInfo = _royaltyInfo;
        _Reserves = _reserves;
        _Fees = _fees;

        emit BuyNFT(NFTID, _to, _tradeId, _LPtokenID);
    }

    function mintNFT(
        uint24[] calldata _ids,
        uint256[] calldata _NFTIDs,
        address _to,
        bool isLimited
    ) external override nonReentrant returns (uint256, uint128) {
        uint256 _length;
        uint128 currentPositionID;
        _length = _ids.length;
        currentPositionID = _IDs.getUint128();
        if (
            _length == type(uint256).min ||
            _length != _NFTIDs.length ||
            _length > 100
        ) revert MidasPair__LengthWrong();
        unchecked {
            (currentPositionID & 0x1 == type(uint128).min) == (isLimited)
                ? currentPositionID += 1
                : currentPositionID += 2;
        }
        lpToken().mint(_to, currentPositionID);

        uint24 originBin;
        uint24 binStep;
        originBin = _ids[0];
        binStep = _ids._checkBinSequence();
        if (originBin < _IDs.getFirstUint24() || originBin < 7974122)
            revert MidasPair__RangeWrong();
        lpInfos[currentPositionID] = originBin.setAll(
            binStep,
            type(uint128).min
        );
        lpTokenAssetsMap[currentPositionID] = _NFTIDs;

        uint24 _id;
        bytes32 _bin;
        for (uint256 i; i < _length; ) {
            _id = _ids[i];
            _bin = _bins[_id];
            if (_bin.decodeX() == type(uint128).min) _tree2.add(_id);
            _checkNFTOwner(_NFTIDs[i]);
            assetLPMap[_NFTIDs[i]] = currentPositionID;
            _bin = _bin.addFirst(1e18);
            _bins[_id] = _bin;
            unchecked {
                ++i;
            }
        }

        emit ERC721PositionMinted(
            currentPositionID,
            originBin,
            binStep,
            _NFTIDs
        );

        bytes32 _reserves;
        _reserves = _Reserves;
        unchecked {
            _reserves = _reserves.addFirst(uint128(_length) * 1e18);
        }
        _Reserves = _reserves;

        _updateIDs(currentPositionID);

        return (_length, currentPositionID);
    }

    function mintFT(
        uint24[] calldata _ids,
        address _to
    ) external override nonReentrant returns (uint128, uint128) {
        bytes32 _reserves;
        bytes32 _tempIDs;
        uint128 currentPositionID;
        uint128 _amountYAddedToPair;
        uint256 _length;

        _reserves = _Reserves;
        _tempIDs = _IDs;
        currentPositionID = _tempIDs.getUint128();
        _length = _ids.length;

        if (_length == type(uint256).min || _length > 100)
            revert MidasPair__LengthWrong();

        unchecked {
            currentPositionID & 0x1 == type(uint128).min
                ? currentPositionID += 2
                : currentPositionID += 1;
        }

        lpToken().mint(_to, currentPositionID);

        uint24 originBin;
        uint24 binStep;
        originBin = _ids[0];
        binStep = _ids._checkBinSequence();
        lpInfos[currentPositionID] = originBin.setAll(
            binStep,
            type(uint128).min
        );

        if (
            _ids[_length - 1] > _tempIDs.getSecondUint24() ||
            originBin < 7974122
        ) revert MidasPair__RangeWrong();

        bytes32 _bin;
        uint24 _mintId;
        uint256[] memory newMap;
        newMap = new uint256[](_length);
        for (uint256 i; i < _length; ) {
            _mintId = _ids[i];
            _bin = _bins[_mintId];
            if (_bin.decodeY() == type(uint128).min) _tree.add(_mintId);
            uint128 _price;
            _price = _getPriceFromBin(_mintId);
            _bin = _bin.addSecond(_price);
            _amountYAddedToPair += _price;
            _bins[_mintId] = _bin;
            binLPMap[_mintId].push(currentPositionID);
            newMap[i] = MAX;

            unchecked {
                ++i;
            }
        }

        if (
            _amountYAddedToPair >
            tokenY().received(
                _reserves.decodeY(),
                _Fees.decodeX(),
                _RoyaltyInfo.decodeY()
            )
        ) revert MidasPair__AmountInWrong();

        _reserves = _reserves.addSecond(_amountYAddedToPair);
        _Reserves = _reserves;

        lpTokenAssetsMap[currentPositionID] = newMap;

        _updateIDs(currentPositionID);

        emit ERC20PositionMinted(
            currentPositionID,
            originBin,
            binStep,
            _length
        );
        return (_amountYAddedToPair, currentPositionID);
    }

    function burn(
        uint128 _LPtokenID,
        address _nftReceiver,
        address _to
    ) external override nonReentrant returns (uint128 amountY) {
        uint256[] memory _tokenIds;
        uint256 _binIdLength;
        uint24 originBin;
        uint24 binStep;
        uint128 amountFee;

        _tokenIds = lpTokenAssetsMap[_LPtokenID];
        _binIdLength = _tokenIds.length;
        (originBin, binStep, amountFee) = lpInfos[_LPtokenID].getAll();
        _checkLPTOwner(_LPtokenID, address(this));
        delete lpTokenAssetsMap[_LPtokenID];
        delete lpInfos[_LPtokenID];

        uint128 amountX;
        uint128 _price;
        uint24 _id;
        bytes32 _bin;
        for (uint24 i; i < _binIdLength; ) {
            unchecked {
                _id = originBin + i * binStep;
            }
            _bin = _bins[_id];
            if (_tokenIds[i] != MAX) {
                tokenX().safeTransferFrom(
                    address(this),
                    _nftReceiver,
                    _tokenIds[i]
                );
                delete assetLPMap[_tokenIds[i]];

                _bin = _bin.subFirst(1e18);
                unchecked {
                    amountX += 1e18;
                }

                if (_bin.decodeX() == type(uint128).min) _tree2.remove(_id);
            } else if (_LPtokenID & 0x1 == type(uint128).min) {
                binLPMap[_id] = binLPMap[_id]._findIndexAndRemove(_LPtokenID);

                _price = _getPriceFromBin(_id);
                _bin = _bin.subSecond(_price);
                unchecked {
                    amountY += _price;
                }

                if (_bin.decodeY() == type(uint128).min) _tree.remove(_id);
            }
            _bins[_id] = _bin;

            unchecked {
                ++i;
            }
        }

        bytes32 _reserves;
        _reserves = _Reserves;
        _reserves = _reserves.sub(amountX, amountY);
        _Reserves = _reserves;

        _updateIDs(type(uint128).min);

        _updateFees(amountFee);

        emit PositionBurned(_LPtokenID, _nftReceiver, amountFee);

        amountY += amountFee;
        tokenY().safeTransfer(_to, amountY);
    }

    /// @notice Collect the protocol fees and send them to the fee recipient.
    /// @dev The protocol fees are not set to zero to save gas by not resetting the storage slot.
    /// @return amountY The amount of token Y collected and sent to the fee recipient

    function collectProtocolFees()
        external
        override
        nonReentrant
        returns (uint128 amountY)
    {
        address _feeRecipient;
        bytes32 fees;
        _feeRecipient = factory.feeRecipient();
        if (msg.sender != _feeRecipient) revert MidasPair__AddressWrong();
        fees = _Fees;
        amountY = fees.decodeY();
        _Fees = fees.sub(amountY, amountY);
        tokenY().safeTransfer(_feeRecipient, amountY);
    }

    function collectLPFees(
        uint128 _LPtokenID,
        address _to
    ) external override nonReentrant returns (uint128 amountFee) {
        bytes32 _lpInfo;
        _checkLPTOwner(_LPtokenID, _to);
        _lpInfo = lpInfos[_LPtokenID];
        amountFee = _lpInfo.getUint128();
        lpInfos[_LPtokenID] = _lpInfo.setUint128(type(uint128).min);
        _updateFees(amountFee);

        tokenY().safeTransfer(_to, amountFee);
        emit ClaimFee(_LPtokenID, _to, amountFee);
    }

    function collectRoyaltyFees()
        external
        override
        nonReentrant
        returns (uint128 _royaltyFees)
    {
        bytes32 _royaltyInfo;
        _royaltyInfo = _RoyaltyInfo;
        _royaltyFees = _royaltyInfo.decodeY();
        _RoyaltyInfo = _royaltyInfo.setSecond(type(uint128).min);
        unchecked {
            for (uint256 i; i < creators.length; ++i) {
                tokenY().safeTransfer(
                    creators[i],
                    (creatorShares[i] * _royaltyFees) / 1e18
                );
            }
        }
    }

    function updateRoyalty(
        uint128 _newRate,
        address payable[] calldata newrecipients,
        uint256[] calldata newshares
    ) external {
        if (msg.sender != address(factory)) revert MidasPair__AddressWrong();
        creators = newrecipients;
        creatorShares = newshares;
        _RoyaltyInfo = _RoyaltyInfo.setFirst(_newRate);
    }

    function flashLoan(
        IMidasFlashLoanCallback receiver,
        uint256[] calldata _tokenIds,
        bytes calldata data
    ) external override nonReentrant {
        if (_tokenIds.length == 0) revert MidasPair__ZeroBorrowAmount();
        if (msg.sender != address(factory)) revert MidasPair__AddressWrong();
        for (uint256 i; i < _tokenIds.length; ) {
            if (tokenX().ownerOf(_tokenIds[i]) != address(this))
                revert MidasPair__NFTOwnershipWrong();
            tokenX().safeTransferFrom(
                address(this),
                address(receiver),
                _tokenIds[i]
            );
            unchecked {
                ++i;
            }
        }

        receiver.MidasFlashLoanCallback(tokenX(), _tokenIds, data);

        for (uint256 i; i < _tokenIds.length; ) {
            if (tokenX().ownerOf(_tokenIds[i]) != address(this))
                revert MidasPair__NFTOwnershipWrong();
            unchecked {
                ++i;
            }
        }

        emit FlashLoan(msg.sender, receiver, _tokenIds);
    }

    /* ========== INTERNAL FUNCTIONS ========== */
    function tokenX() private pure returns (IERC721) {
        return IERC721(_getArgAddress(0));
    }

    function tokenY() private pure returns (IERC20) {
        return IERC20(_getArgAddress(20));
    }

    function lpToken() private pure returns (LPToken) {
        return LPToken(_getArgAddress(40));
    }

    function _rate() private pure returns (uint128) {
        return _getArgUint128(60);
    }

    function _getPriceFromBin(uint24 _id) private pure returns (uint128) {
        int256 _realId;
        uint256 _price;
        // 2^23 = 8388608
        _realId = int256(uint256(_id)) - 8388608;
        // 2^128 * 1.0001 = 340316395157630557309720944892511388277
        _price = uint256(340316395157630557309720944892511388277).pow(_realId);
        _price = _price.mulShiftRoundDownS();
        if (_price > type(uint128).max) revert MidasPair__PriceOverflow();
        return uint128(_price);
    }

    function _checkNFTOwner(uint256 _NFTID) internal view {
        if (
            assetLPMap[_NFTID] != type(uint128).min ||
            tokenX().ownerOf(_NFTID) != address(this)
        ) revert MidasPair__NFTOwnershipWrong();
    }

    function _checkLPTOwner(uint256 _lpTokenID, address _to) internal view {
        if (_to != lpToken().ownerOf(_lpTokenID))
            revert MidasPair__AddressWrong();
    }

    function _updateIDs(uint128 currentPositionID) internal {
        uint24 bestOfferID;
        uint24 floorPriceID;
        bytes32 _ids;
        (bestOfferID, floorPriceID) = _tree.updateBins(_tree2);
        _ids = _IDs;
        if (currentPositionID == type(uint128).min) {
            _ids = _ids.setBothUint24(bestOfferID, floorPriceID);
        } else {
            _ids = bestOfferID.setAll(floorPriceID, currentPositionID);
        }
        _IDs = _ids;
    }

    function _updateFees(uint128 amountX) internal {
        bytes32 _fees;
        _fees = _Fees;
        _fees = _fees.subFirst(amountX);
        _Fees = _fees;
    }

    function _updateLpInfo(uint128 _lpToken, uint128 amountY) internal {
        bytes32 _info;
        _info = lpInfos[_lpToken];
        _info = _info.addUint128(amountY);
        lpInfos[_lpToken] = _info;
    }

    function _updateAssetMapBuy(
        uint128 _lpTokenID,
        uint256 _NFTID
    ) internal returns (uint24 _currentID) {
        uint256[] memory _map;
        uint24 _start;
        uint24 _binStep;
        uint24 _index;
        uint256 temp;
        uint256 asset;
        _map = lpTokenAssetsMap[_lpTokenID];
        (_start, _binStep) = lpInfos[_lpTokenID].getBothUint24();
        temp = MAX;
        for (uint24 i; i < _map.length; ) {
            asset = _map[i];
            if (asset != MAX) {
                if (temp == MAX) {
                    temp = asset;
                    _index = i;
                    lpTokenAssetsMap[_lpTokenID][i] = MAX;
                    if (temp == _NFTID) break;
                } else if (asset == _NFTID) {
                    lpTokenAssetsMap[_lpTokenID][i] = temp;
                    break;
                }
            }
            unchecked {
                ++i;
            }
        }
        unchecked {
            _currentID = _index * _binStep + _start;
        }
    }

    function _updateAssetMapSell(
        uint128 _lpTokenID,
        uint24 _tradeID,
        uint256 _NFTID
    ) internal {
        uint24 _index;
        uint24 _start;
        uint24 _binStep;
        (_start, _binStep) = lpInfos[_lpTokenID].getBothUint24();
        if (_binStep != type(uint24).min) {
            unchecked {
                _index = (_tradeID - _start) / _binStep;
            }
        } else {
            uint256[] memory _map;
            _map = lpTokenAssetsMap[_lpTokenID];
            while (_map[_index] != MAX) {
                unchecked {
                    ++_index;
                }
            }
        }
        lpTokenAssetsMap[_lpTokenID][_index] = _NFTID;
    }
}
