// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Ownable.sol";

contract Developers is Ownable{

    mapping(address => bool) private _DevTeam;

    modifier onlyDev() {
        require(isDev(_msgSender()), "Developers: caller is not the developer");
        _;
    }

    function addDev(address member) public onlyOwner {
        require(!has(member), "Developers: account is already considered a developer");
        _DevTeam[member] = true;
    }


    function removeDev(address member) public onlyOwner {
        require(has(member), "Developers: account is not considered a developer");
        _DevTeam[member] = false;
    }


    function isDev(address member) public view returns(bool) {
        return has(member);
    }

     function has(address member) internal view returns (bool) {
        require(member != address(0), "Developers: account is the zero address");
        return _DevTeam[member];
    }
}