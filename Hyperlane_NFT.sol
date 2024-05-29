// Original license: SPDX_License_Identifier: MIT
pragma solidity =0.8.19;
/**
 * @author Womex
 * @title WomexNFT721
 */
contract WomexNFT721 is TokenRouter, ERC721Enumerable, Pausable, ReentrancyGuard {
    event NFTMinted(address indexed minter, uint256 indexed itemId, uint256 feeEarnings, address indexed referrer, uint256 referrerEarnings);
    event NFTSent(address indexed from, uint32 indexed dstChainId, address indexed receiver, uint256 tokenId, uint256 feeEarned);
    event NFTReceived(bytes32 indexed srcAddress, uint32 indexed srcChainId, address indexed receiver, uint256 tokenId);
    event FeeEarningsClaimed(address indexed collector, uint256 claimedAmount);
    event ReferrerEarningsClaimed(address indexed referrer, uint256 claimedAmount);

    uint256 public immutable minTokenId;
    uint256 public immutable maxTokenId;
    uint256 public tokenCounter;

    string public _tokenBaseURI;
    string public _tokenURIExtension;

    address public feeCollector;
    uint256 public bridgeFee;
    uint256 public mintFee;
    uint256 public feeToCollect;
    uint256 public claimedFee;

    uint16 public constant DENOMINATOR = 10000; // 100%
    uint16 public commonRefBips;

    mapping(address => uint16) public personalRefBips;
    mapping(address => uint256) public refTxsCount;
    mapping(address => uint256) public refAmountToClaim;
    mapping(address => uint256) public refAmountClaimed;

    constructor(
        address _mailbox,
        address _feeCollector,
        uint256 _mintFee,
        uint256 _bridgeFee,
        uint256 _totalSupply,
        uint256 _idMultiplier
    ) ERC721('Womex', 'WOW') TokenRouter(_mailbox) {
        require(_feeCollector != address(0), 'Fee collector must be non-zero');

        feeCollector = _feeCollector;
        mintFee = _mintFee;
        bridgeFee = _bridgeFee;
        minTokenId = _totalSupply * _idMultiplier + 1;
        maxTokenId = _totalSupply * (_idMultiplier + 1);
        tokenCounter = _totalSupply * _idMultiplier + 1;
    }

    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    function setMintFee(uint256 _mintFee) external onlyOwner {
        mintFee = _mintFee;
    }

    function setBridgeFee(uint256 _bridgeFee) external onlyOwner {
        bridgeFee = _bridgeFee;
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), 'WomexNFT721: Fee collector must be non-zero address');
        feeCollector = _feeCollector;
    }

    function claimFees() external nonReentrant {
        require(_msgSender() == feeCollector, 'WomexNFT721: Only fee collector allowed');

        uint256 currentEarnings = feeToCollect;
        require(currentEarnings != 0, 'WomexNFT721: Nothing to claim');
        feeToCollect = 0;
        claimedFee += currentEarnings;

        (bool success, ) = payable(feeCollector).call{value: currentEarnings}('');
        require(success, 'WomexNFT721: Failed to send Ether');

        emit FeeEarningsClaimed(_msgSender(), currentEarnings);
    }

    function mint() external payable nonReentrant whenNotPaused {
        require(msg.value == mintFee, 'WomexNFT721: Insufficient mint fee');
        uint256 nextId = tokenCounter;
        require(nextId <= maxTokenId, 'WomexNFT721: Mint exceeds limit');

        ++tokenCounter;
        feeToCollect += mintFee;

        _safeMint(_msgSender(), nextId);

        emit NFTMinted(_msgSender(), nextId, mintFee, address(0), 0);
    }
    function batchMint(uint256 count) external payable nonReentrant whenNotPaused {
        require(msg.value == mintFee * count, 'WomexNFT721: Insufficient mint fee');

        for (uint256 i = 0; i < count; i++) {
            uint256 nextId = tokenCounter;
            require(nextId <= maxTokenId, 'WomexNFT721: Mint exceeds limit');

            ++tokenCounter;
            feeToCollect += mintFee;

            _safeMint(_msgSender(), nextId);

            emit NFTMinted(_msgSender(), nextId, mintFee, address(0), 0);
        }
    }

    function mintWithReferrer(address referrer) external payable nonReentrant whenNotPaused {
        require(_msgSender() != referrer && referrer != address(0), 'WomexNFT721: Invalid referrer address');
        require(msg.value == mintFee, 'WomexNFT721: Insufficient mint fee');

        uint256 nextId = tokenCounter;
        require(nextId <= maxTokenId, 'WomexNFT721: Mint exceeds limit');

        uint256 fee = mintFee;
        uint256 refShares = calculateRefShares(referrer, fee);

        ++tokenCounter;
        feeToCollect += fee - refShares;
        refAmountToClaim[referrer] += refShares;
        ++refTxsCount[referrer];

        _safeMint(_msgSender(), nextId);

        emit NFTMinted(_msgSender(), nextId, mintFee, referrer, refShares);
    }
    function batchMintWithReferrer(uint256 count, address referrer) external payable nonReentrant whenNotPaused {
        require(_msgSender() != referrer && referrer != address(0), 'WomexNFT721: Invalid referrer address');
        require(msg.value == mintFee * count, 'WomexNFT721: Insufficient mint fee');

        for (uint256 i = 0; i < count; i++) {
            uint256 nextId = tokenCounter;
            require(nextId <= maxTokenId, 'WomexNFT721: Mint exceeds limit');

            uint256 fee = mintFee;
            uint256 refShares = calculateRefShares(referrer, fee);

            ++tokenCounter;
            feeToCollect += fee - refShares;
            refAmountToClaim[referrer] += refShares;
            ++refTxsCount[referrer];

            _safeMint(_msgSender(), nextId);

            emit NFTMinted(_msgSender(), nextId, mintFee, referrer, refShares);
        }
    }

    function transferRemote(
        uint32 _dstChain,
        bytes32 _receiver,
        uint256 _tokenId
        ) external payable override(TokenRouter) nonReentrant whenNotPaused returns (bytes32 messageId) {
        require(_receiver != bytes32(0), 'WomexNFT721: Invalid receiver');
        require(_isApprovedOrOwner(_msgSender(), _tokenId), 'WomexNFT721: send caller is not owner nor approved');

        uint256 fee = getHyperlaneMessageFee(_dstChain);

        require(msg.value >= fee + bridgeFee, 'WomexNFT721: Incorrect message value');
        feeToCollect += bridgeFee;

        messageId = _transferRemote(_dstChain, _receiver, _tokenId, msg.value - bridgeFee);

        emit NFTSent(msg.sender, _dstChain, address(uint160(uint256(_receiver))), _tokenId, bridgeFee);
    }

    function getHyperlaneMessageFee(uint32 _dstChain) public view returns (uint256) {
        uint256 fee = _quoteDispatch(_dstChain, "");
        return fee;
    }

    ///////////////
    ///// REF /////
    ///////////////
    function setCommonRefBips(uint16 _bips) external onlyOwner {
        require(_bips <= DENOMINATOR, 'ReferralSystem: Referral bips are too high');
        commonRefBips = _bips;
    }

    function setPersonalRefBips(address referrer, uint16 bips) external onlyOwner {
        require(bips <= DENOMINATOR, 'ReferralSystem: Referral bips are too high');
        personalRefBips[referrer] = bips;
    }

    function setPersonalRefBipsBatch(address[] calldata referrers, uint16 bips) external onlyOwner {
        require(bips <= DENOMINATOR, 'ReferralSystem: Referral bips are too high');
        for (uint256 i = 0; i < referrers.length; i++) {
            personalRefBips[referrers[i]] = bips;
        }
    }

    function claimRefEarnings() external nonReentrant {
        uint256 amountToClaim = refAmountToClaim[_msgSender()];
        require(amountToClaim > 0, 'Nothing to claim');

        address referrer = _msgSender();
        refAmountToClaim[referrer] = 0;
        refAmountClaimed[referrer] += amountToClaim;

        (bool success, ) = payable(referrer).call{value: amountToClaim}('');
        require(success, 'ReferralSystem: Failed to send Ether');

        emit ReferrerEarningsClaimed(referrer, amountToClaim);
    }

    function calculateRefShares(address referrer, uint256 amount) public view virtual returns (uint256) {
        uint256 referrerBips = personalRefBips[referrer];
        uint256 referrerShareBips = referrerBips == 0 ? commonRefBips : referrerBips;
        if (referrerShareBips == 0) {
            return 0;
        }

        uint256 referrerEarnings = (amount * referrerShareBips) / DENOMINATOR;
        return referrerEarnings;
    }

    //////////////////
    //// override ////
    //////////////////
    function balanceOf(address _account) public view virtual override(TokenRouter, ERC721, IERC721) returns (uint256) {
        return ERC721.balanceOf(_account);
    }

    function _transferFromSender(uint256 _tokenId) internal virtual override returns (bytes memory) {
        require(ownerOf(_tokenId) == msg.sender, '!owner');
        _burn(_tokenId);
        return bytes(''); // no metadata
    }

    function _transferTo(
        address _recipient,
        uint256 _tokenId,
        bytes calldata // no metadata
    ) internal virtual override {
        _safeMint(_recipient, _tokenId);
    }

    function _contextSuffixLength() internal view override(Context, ContextUpgradeable) returns (uint256) {
        return 0;
    }

    function _msgData() internal view override(Context, ContextUpgradeable) returns (bytes calldata) {
        return msg.data;
    }

    function _msgSender() internal view override(Context, ContextUpgradeable) returns (address) {
        return msg.sender;
    }
    //////////////////////////////
    ////////// URI ///////////////
    //////////////////////////////
    function setTokenBaseURI(
        string calldata _newTokenBaseURI,
        string calldata _fileExtension
    ) external onlyOwner {
        _tokenBaseURI = _newTokenBaseURI;
        _tokenURIExtension = _fileExtension;
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    _tokenBaseURI,
                    Strings.toString(tokenId),
                    _tokenURIExtension
                )
            );
    }

    //////////////////////////////
    ////// escape mechanism //////
    //////////////////////////////
    function resqueFunds() external {
        require(_msgSender() == feeCollector || _msgSender() == owner(), 'Resque: Only fee collector or owner allowed');
        (bool success, ) = payable(msg.sender).call{value: address(this).balance}('');
        require(success, 'Resque:  Failed to send Ether');
    }
}
