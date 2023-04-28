// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./libraries/TokenHelper.sol";
// import "./libraries/PriceHelper.sol";

import "./MidasErrors.sol";

import "./interfaces/IWETH.sol";
import "./interfaces/IMidasRouter.sol";
import "./interfaces/IMidasPair721.sol";
import "./interfaces/IMidasFactory721.sol";

/// @title Midas Router
/// @author midaswap
/// @notice Router for trades and liquidity managements against the Midaswap

contract MidasRouter is IMidasRouter {
    using TokenHelper for IERC20;
    using TokenHelper for IWETH;

    IWETH public weth;
    IMidasFactory721 public factory;

    constructor(IWETH _weth, IMidasFactory721 _factory) {
        weth = _weth;
        factory = _factory;
    }

    receive() external payable {
        assert(msg.sender == address(weth)); // only accept ETH via fallback from the WETH contract
    }

    /// @notice The function to add ERC721 liquidity into pair
    /// @param _tokenX      The address of ERC721 assets
    /// @param _tokenY      The address of ERC20 assets
    /// @param _ids         The array of bin Ids where to add liquidity
    /// @param _tokenIds    The array of NFT tokenIds
    /// @param _deadline    The deadline of the tx
    /// @return idAmount    The amount of ids
    /// @return lpTokenId   The ID of the LP token
    function addLiquidityERC721(
        address _tokenX,
        address _tokenY,
        uint24[] calldata _ids,
        uint256[] calldata _tokenIds,
        uint256 _deadline
    ) external override returns (uint256 idAmount, uint128 lpTokenId) {
        if (_deadline < block.timestamp) revert Router__Expired();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        for (uint256 i; i < _tokenIds.length; ) {
            IERC721(_tokenX).safeTransferFrom(msg.sender, _pair, _tokenIds[i]);
            unchecked {
                ++i;
            }
        }
        (idAmount, lpTokenId) = IMidasPair721(_pair).mintNFT(
            _ids,
            _tokenIds,
            msg.sender,
            false
        );
    }

    /// @notice The function to add ERC20 liquidity into pair
    /// @param _tokenX      The address of ERC721 assets
    /// @param _tokenY      The address of ERC20 assets
    /// @param _ids         The array of bin Ids where to add liquidity
    /// @param _deadline    The deadline of the tx
    /// @return idAmount    The amount of ids
    /// @return lpTokenId   The ID of the LP token
    function addLiquidityERC20(
        address _tokenX,
        address _tokenY,
        uint24[] calldata _ids,
        uint256 _deadline
    ) external override returns (uint256 idAmount, uint128 lpTokenId) {
        if (_deadline < block.timestamp) revert Router__Expired();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        uint256 _amount = _getAmountsToAdd(_pair, _ids);
        IERC20(_tokenY).safeTransferFrom(msg.sender, _pair, _amount);
        (idAmount, lpTokenId) = IMidasPair721(_pair).mintFT(_ids, msg.sender);
    }

    /// @notice The function to add ETH liquidity into pair
    function addLiquidityETH(
        address _tokenX,
        address _tokenY,
        uint24[] calldata _ids,
        uint256 _deadline
    ) external payable override returns (uint256 idAmount, uint128 lpTokenId) {
        if (_deadline < block.timestamp) revert Router__Expired();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        uint256 _amount = _getAmountsToAdd(_pair, _ids);
        if (_tokenY != address(weth)) revert Router__WrongPair();
        if (msg.value < _amount) revert Router__WrongAmount();
        _wethDepositAndTransfer(_pair, msg.value);
        (idAmount, lpTokenId) = IMidasPair721(_pair).mintFT(_ids, msg.sender);
    }

    /// @notice The function to remove liquidity from pair
    /// @param _tokenX      The address of ERC721 assets
    /// @param _tokenY      The address of ERC20 assets
    /// @param _lpTokenId   The ID of LP token
    /// @param _deadline    The deadline of the tx
    /// @return ftAmount    The amount of ERC20 the lp can get
    function removeLiquidity(
        address _tokenX,
        address _tokenY,
        uint128 _lpTokenId,
        uint256 _deadline
    ) external override returns (uint128 ftAmount) {
        if (_deadline < block.timestamp) revert Router__Expired();

        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        address _lpToken = factory.getLPTokenERC721(_tokenX, _tokenY);
        IERC721(_lpToken).safeTransferFrom(msg.sender, _pair, _lpTokenId);
        (ftAmount) = IMidasPair721(_pair).burn(
            _lpTokenId,
            msg.sender,
            msg.sender
        );
    }

    /// @notice The function to remove liquidity(ETH) from pair
    function removeLiquidityETH(
        address _tokenX,
        address _tokenY,
        uint128 _lpTokenId,
        uint256 _deadline
    ) external override returns (uint128 ftAmount) {
        if (_deadline < block.timestamp) revert Router__Expired();
        // require(_tokenY == address(weth), "MIDASROUTER: WRONG PAIR");
        if (_tokenY != address(weth)) revert Router__WrongPair();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        address _lpToken = factory.getLPTokenERC721(_tokenX, _tokenY);
        IERC721(_lpToken).safeTransferFrom(msg.sender, _pair, _lpTokenId);
        (ftAmount) = IMidasPair721(_pair).burn(
            _lpTokenId,
            msg.sender,
            address(this)
        );
        weth.withdraw(ftAmount);
        _safeTransferETH(msg.sender, ftAmount);
    }

    /// @notice The function to sell ERC721 into the pair
    /// @param _tokenX      The address of ERC721 assets
    /// @param _tokenY      The address of ERC20 assets
    /// @param _tokenIds    The array of NFT tokenIds
    /// @param _deadline    The deadline of the tx
    /// @return _ftAmount    The amount of ERC20 the lp can get
    function sellItems(
        address _tokenX,
        address _tokenY,
        uint256[] calldata _tokenIds,
        uint256 _deadline
    ) external override returns (uint128 _ftAmount) {
        if (_deadline < block.timestamp) revert Router__Expired();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        for (uint256 i; i < _tokenIds.length; ) {
            IERC721(_tokenX).safeTransferFrom(msg.sender, _pair, _tokenIds[i]);
            _ftAmount = IMidasPair721(_pair).sellNFT(_tokenIds[i], msg.sender);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The function to sell ERC721 and get ETH
    function sellItemsToETH(
        address _tokenX,
        address _tokenY,
        uint256[] calldata _tokenIds,
        uint256 _deadline
    ) external payable override returns (uint128 _ftAmount) {
        if (_deadline < block.timestamp) revert Router__Expired();
        if (_tokenY != address(weth)) revert Router__WrongPair();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        for (uint256 i; i < _tokenIds.length; ) {
            IERC721(_tokenX).safeTransferFrom(msg.sender, _pair, _tokenIds[i]);
            _ftAmount = IMidasPair721(_pair).sellNFT(
                _tokenIds[i],
                address(this)
            );
            weth.withdraw(_ftAmount);
            _safeTransferETH(msg.sender, _ftAmount);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The function to buy ERC721 from the pair
    /// @param _tokenX      The address of ERC721 assets
    /// @param _tokenY      The address of ERC20 assets
    /// @param _tokenIds    The array of NFT tokenIds
    /// @param _deadline    The deadline of the tx
    /// @return _ftAmount    The amount of ERC20 the lp need to swap into the pair
    function buyItems(
        address _tokenX,
        address _tokenY,
        uint256[] calldata _tokenIds,
        uint256 _deadline
    ) external override returns (uint128 _ftAmount) {
        if (_deadline < block.timestamp) revert Router__Expired();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        _ftAmount = _getMinAmountIn(_pair, _tokenIds);
        IERC20(_tokenY).safeTransferFrom(msg.sender, _pair, _ftAmount);
        for (uint256 i; i < _tokenIds.length; ) {
            IMidasPair721(_pair).buyNFT(_tokenIds[i], msg.sender);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The function to buy ERC721 with ETH from the pair
    function buyItemsWithETH(
        address _tokenX,
        address _tokenY,
        uint256[] calldata _tokenIds,
        uint256 _deadline
    ) external payable override returns (uint128 _ftAmount) {
        if (_deadline < block.timestamp) revert Router__Expired();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        _ftAmount = _getMinAmountIn(_pair, _tokenIds);
        if (_tokenY != address(weth)) revert Router__WrongPair();
        if (msg.value < _ftAmount) revert Router__WrongAmount();
        _wethDepositAndTransfer(_pair, msg.value);
        for (uint256 i; i < _tokenIds.length; ) {
            IMidasPair721(_pair).buyNFT(_tokenIds[i], msg.sender);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The function to open limit order
    /// @param _tokenX      The address of ERC721 assets
    /// @param _tokenY      The address of ERC20 assets
    /// @param _ids         The array of bin Ids where to add liquidity
    /// @param _tokenIds    The array of NFT tokenIds
    /// @param _deadline    The deadline of the tx
    /// @return idAmount    The amount of ids
    /// @return lpTokenId   The ID of the LP token
    function openLimitOrder(
        address _tokenX,
        address _tokenY,
        uint24[] calldata _ids,
        uint256[] calldata _tokenIds,
        uint256 _deadline
    ) external override returns (uint256 idAmount, uint128 lpTokenId) {
        if (_deadline < block.timestamp) revert Router__Expired();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        for (uint i; i < _tokenIds.length; ) {
            IERC721(_tokenX).safeTransferFrom(msg.sender, _pair, _tokenIds[i]);
            unchecked {
                ++i;
            }
        }
        (idAmount, lpTokenId) = IMidasPair721(_pair).mintNFT(
            _ids,
            _tokenIds,
            msg.sender,
            true
        );
    }


    /// @notice The function to open multiple limit orders
    /// @param _tokenX        The address of ERC721 assets
    /// @param _tokenY        The address of ERC20 assets
    /// @param _ids[]         The array of bin ids where to add liquidity
    /// @param _tokenIds[]    The array of NFT tokenIds
    /// @param _deadline      The deadline of the tx
    /// @return lpTokenIds  The ids of the LP tokens
    function openMultiLimitOrders(
        address _tokenX,
        address _tokenY,
        uint24[] calldata _ids,
        uint256[] calldata _tokenIds,
        uint256 _deadline
    ) external returns (uint128[] memory lpTokenIds) {
        if (_deadline < block.timestamp) revert Router__Expired();
        uint256 _length = _tokenIds.length;
        if (_ids.length != _length) revert Router__WrongAmount();
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        lpTokenIds = new uint128[](_ids.length);
        uint24[] memory _id = new uint24[](1);
        uint256[] memory _tokenId = new uint256[](1);
        for (uint256 i; i < _length; ) {
            IERC721(_tokenX).safeTransferFrom(msg.sender, _pair, _tokenIds[i]);
            _id[0] = _ids[i];
            _tokenId[0] = _tokenIds[i];
            ( , uint128 lpTokenId) = IMidasPair721(_pair).mintNFT(
                _id,
                _tokenId,
                msg.sender,
                true
            );
            lpTokenIds[i] = lpTokenId;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The function to open limit order
    /// @param _tokenX      The address of ERC721 assets
    /// @param _tokenY      The address of ERC20 assets
    /// @param _lpTokenId   The ID of LP token
    /// @return _feeClaimed The amount of fee claimed
    function claimFee(
        address _tokenX,
        address _tokenY,
        uint128 _lpTokenId
    ) external returns (uint128 _feeClaimed) {
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        _feeClaimed = IMidasPair721(_pair).collectLPFees(
            _lpTokenId,
            msg.sender
        );
    }

    /// @notice The function to claim all fee
    /// @param _tokenX      The address of ERC721 assets
    /// @param _tokenY      The address of ERC20 assets
    /// @param _lpTokenIds   The array of LP token ID
    /// @return _feeClaimed The amount of fee claimed
    function claimAll(
        address _tokenX,
        address _tokenY,
        uint128[] calldata _lpTokenIds
    ) external returns (uint128 _feeClaimed) {
        address _pair = factory.getPairERC721(_tokenX, _tokenY);
        for(uint i ; i < _lpTokenIds.length ; ){
            _feeClaimed += IMidasPair721(_pair).collectLPFees(
            _lpTokenIds[i],
            msg.sender
            );
            unchecked{
                ++i;
            }
        }
    }

    function getMinAmountIn(address _pair, uint256[] calldata _tokenIds)
        external
        view
        returns (uint128)
    {
        return _getMinAmountIn(_pair , _tokenIds);
    }


    function getAmountsToAdd(address _pair, uint24[] calldata _ids)
        external
        pure
        returns (uint128)
    {
        return _getAmountsToAdd(_pair , _ids);
    }

    /// @notice The function to get the amount of ERC20 need to transfer 
    /// @param _pair        The address of pair
    /// @param _ids         The array of bin Ids where to add liquidity
    /// @return ftAmount    The amount of ERC20 need to transfer
    function _getAmountsToAdd(address _pair, uint24[] calldata _ids)
        internal
        pure
        returns (uint128 ftAmount)
    {
        for (uint256 i; i < _ids.length; ) {
            ftAmount += IMidasPair721(_pair).getPriceFromBin(_ids[i]);
            unchecked {
                ++i;
            }
        }
    }

    // /// @notice The function to quote a set of NFTs
    // /// @param _pair        The address of pair
    // /// @param _tokenIds    The array of tokenIds to be quoted
    // /// @return totalAmount The amount of ERC20 need to transfer
    function _getMinAmountIn(address _pair, uint256[] calldata _tokenIds)
        internal
        view
        returns (uint128 totalAmount)
    {
        uint256 _length = _tokenIds.length;
        uint128[] memory uniqueElements = new uint128[](_length);
        uint256[] memory uniqueCounts = new uint256[](_length);
        uint256 uniqueCount;
        uint128 item;
        for (uint256 i ; i < _length; ) {
            bool isRepeated;
            item = IMidasPair721(_pair).getLPFromNFT(_tokenIds[i]);
            for (uint256 j ; j < uniqueCount; ) {
                if (item == uniqueElements[j]) {
                    isRepeated = true;
                    unchecked{
                        uniqueCounts[j]++;
                    }
                    break;
                }
                unchecked{
                    ++j;
                }
            }
            if (!isRepeated) {
                uniqueElements[uniqueCount] = item;
                uniqueCounts[uniqueCount] = 1;
                unchecked{
                    uniqueCount++;
                }
            }
            unchecked{
                ++i;
            }
        }
        for (uint i; i < uniqueCount; ) {
            totalAmount += IMidasPair721(_pair).getBinParamFromLP(
                uniqueElements[i],
                uniqueCounts[i]
            );
            unchecked{
                ++i;
            }
        }
        (uint256 _rate1, , uint256 _rate2) = IMidasPair721(_pair).feeParameters();
        unchecked {
            totalAmount = uint128( (totalAmount * (1e18 + _rate1 + _rate2)) / 1e18 + 1 );
        }
    }

    // /// @notice The function to quote a set of NFTs
    // /// @param _pair        The address of pair
    // /// @param _tokenIds    The array of tokenIds to be quoted
    // /// @return totalAmount The amount of ERC20 need to transfer
    // function _getMinAmountIn(address _pair, uint256[] calldata _tokenIds)
    //     public
    //     view
    //     returns (uint128 totalAmount)
    // {
    //     uint256 _length = _tokenIds.length;
    //     uint128[] memory lpList = new uint128[](_length);
    //     for (uint i; i < _length; ) {
    //         lpList[i] = IMidasPair721(_pair).getLPFromNFT(_tokenIds[i]);
    //         unchecked {
    //             ++i;
    //         }
    //     }
    //     uint256[] memory amountList;
    //     (lpList, amountList) = PriceHelper.sortAndSplit(lpList);
    //     _length = lpList.length;

    //     unchecked {
    //         for (uint i; i < _length; ++i) {
    //             totalAmount += IMidasPair721(_pair).getBinParamFromLP(
    //                 lpList[i],
    //                 amountList[i]
    //             );
    //         }
    //     }
    //     (uint256 _rate1, , uint256 _rate2) = IMidasPair721(_pair).feeParameters();
    //     unchecked {
    //         totalAmount = uint128( (totalAmount * (1e18 + _rate1 + _rate2)) / 1e18 + 1 );
    //     }
    // }

    function _safeTransferETH(address _to, uint256 _amount) private {
        (bool success, ) = _to.call{value: _amount}("");
        require(success == true);
    }

    function _wethDepositAndTransfer(address _to, uint256 _amount) private {
        weth.deposit{value: _amount}();
        weth.transfer(_to, _amount);
    }

}
