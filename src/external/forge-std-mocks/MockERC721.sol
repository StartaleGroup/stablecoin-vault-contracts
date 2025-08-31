// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

// Mock ERC721 for forge-std compatibility
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    
    string public name;
    string public symbol;
    
    function initialize(string memory _name, string memory _symbol) external {
        name = _name;
        symbol = _symbol;
    }
    
    function approve(address to, uint256 tokenId) external {
        getApproved[tokenId] = to;
    }
    
    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
    
    function transferFrom(address from, address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
        balanceOf[from]--;
        balanceOf[to]++;
    }
    
    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
        balanceOf[to]++;
    }
}
