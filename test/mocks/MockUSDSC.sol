// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockUSDSC {
  string public constant NAME = 'Mock USDSC';
  string public constant SYMBOL = 'USDSC';
  uint8 public constant DECIMALS = 6;

  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;
  uint256 public totalSupply;

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Approval(address indexed owner, address indexed spender, uint256 amount);

  function approve(address spender, uint256 amt) external returns (bool) {
    allowance[msg.sender][spender] = amt;
    emit Approval(msg.sender, spender, amt);
    return true;
  }

  function transfer(address to, uint256 amt) external returns (bool) {
    _transfer(msg.sender, to, amt);
    return true;
  }

  function transferFrom(address from, address to, uint256 amt) external returns (bool) {
    uint256 a = allowance[from][msg.sender];
    require(a >= amt, 'allow');
    allowance[from][msg.sender] = a - amt;
    _transfer(from, to, amt);
    return true;
  }

  function _transfer(address from, address to, uint256 amt) internal {
    require(balanceOf[from] >= amt, 'bal');
    balanceOf[from] -= amt;
    balanceOf[to] += amt;
    emit Transfer(from, to, amt);
  }

  function mint(address to, uint256 amt) external {
    balanceOf[to] += amt;
    totalSupply += amt;
    emit Transfer(address(0), to, amt);
  }

  function burn(address from, uint256 amt) external {
    require(balanceOf[from] >= amt, 'bal');
    balanceOf[from] -= amt;
    totalSupply -= amt;
    emit Transfer(from, address(0), amt);
  }
}
