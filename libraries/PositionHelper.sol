// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

library PositionHelper {
    error MidasPair__BinSequenceWrong();

    function _checkBinSequence(
        uint24[] calldata _binIds
    ) internal pure returns (uint24 commonDiff) {
        if (_binIds.length > 1) {
            commonDiff = _binIds[1] - _binIds[0];
            for (uint i = 2; i < _binIds.length; ) {
                if (_binIds[i] - _binIds[i - 1] != commonDiff)
                    revert MidasPair__BinSequenceWrong();
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _removeFirstItem(
        uint128[] memory arr
    ) public pure returns (uint128[] memory) {
        uint128[] memory newArr = new uint128[](arr.length - 1);
        for (uint i; i < newArr.length; ) {
            newArr[i] = arr[i + 1];
            unchecked {
                ++i;
            }
        }
        return newArr;
    }

    function _findIndexAndRemove(
        uint128[] memory arr,
        uint128 target
    ) internal pure returns (uint128[] memory) {
        uint j;
        uint _length = arr.length - 1;
        uint128[] memory newArr = new uint128[](_length);
        for (uint i; i < _length; ) {
            if (arr[i] == target) {
                unchecked {
                    j = 1;
                }
            }
            unchecked {
                newArr[i] = arr[i + j];
                ++i;
            }
        }
        return newArr;
    }
}
