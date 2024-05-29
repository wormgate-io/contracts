/**
* @author Womex
* @title WomexRefuel
*/
contract WomexRefuel is NonblockingLzApp {

    uint256 private fee;
    uint private varyingFee;
    uint public constant DENOMINATOR = 100;

    uint16 public constant FUNCTION_TYPE_SEND = 0;

    constructor(address _lzEndpoint) NonblockingLzApp(_lzEndpoint) {}

    function _nonblockingLzReceive(uint16, bytes memory, uint64, bytes memory) internal virtual override {}

    function estimateSendFee(
        uint16 _dstChainId,
        bytes memory payload,
        bytes memory _adapterParams
    ) public view virtual returns (uint nativeFee, uint zroFee) {
        (nativeFee, zroFee) = lzEndpoint.estimateFees(_dstChainId, address(this), payload, false, _adapterParams);
        nativeFee += nativeFee * varyingFee / DENOMINATOR;
        nativeFee += fee;
        return (nativeFee, zroFee);
    }

    function refuel(
        uint16 _dstChainId,
        bytes memory _toAddress,
        bytes memory _adapterParams
    ) external payable virtual {
        _checkGasLimit(_dstChainId, FUNCTION_TYPE_SEND, _adapterParams, 0);

        (uint nativeFee,) = estimateSendFee(_dstChainId, _toAddress, _adapterParams);
        nativeFee -= fee;
        nativeFee = nativeFee * DENOMINATOR / (varyingFee + DENOMINATOR);
        require(msg.value >= nativeFee, "Not enough gas to send");

        _lzSend(_dstChainId, _toAddress, payable(msg.sender), address(0x0), _adapterParams, nativeFee);
    }

    function setFixedFee(uint256 _fee) external onlyOwner {
        fee = _fee;
    }

    function getFixedFee() external view returns (uint256) {
        return fee;
    }
    function setVaryingFee(uint256 _fee) external onlyOwner {
        varyingFee = _fee;
    }
    function getVaryingFee() external view returns (uint256) {
        return varyingFee;
    }
    function withdraw() external payable onlyOwner {
        (bool success,) = payable(msg.sender).call{value: address(this).balance}("");
        require(success);
    }
}
