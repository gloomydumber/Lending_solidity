// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract DreamAcademyLending {
    IPriceOracle priceOracle;
    IERC20 reserveToken;

    uint256 total_collateral_token;
    uint256 total_collateral_ether;

    mapping(address => uint256) collateral_ether;
    mapping(address => uint256) collateral_token;
    mapping(address => uint256) debt_token;

    constructor(IPriceOracle _priceOracle, address _reserveToken) {
        priceOracle = _priceOracle;
        reserveToken = IERC20(_reserveToken);
    }

    function initializeLendingProtocol(address _reserveToken) external payable {
        reserveToken = IERC20(_reserveToken);
        IERC20(_reserveToken).transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address _token, uint256 _amount) external payable {
        if (_token == address(0x0)) {
            require(_amount == msg.value, "deposit amount should be same as ether value.");
            collateral_ether[msg.sender] += msg.value;
            total_collateral_ether += msg.value;
        } else {
            require(IERC20(_token).balanceOf(msg.sender) >= _amount, "not enough balance to deposit");
            IERC20(_token).transferFrom(msg.sender, address(this), _amount);
            collateral_token[msg.sender] += _amount;
            total_collateral_token += _amount;
        }
    }

    function borrow(address _token, uint256 _amount) external {
        uint256 priceOfBorrowing = priceOracle.getPrice(_token);
        uint256 priceOfReserveToken = priceOracle.getPrice(address(reserveToken));
        uint256 priceOfEther = priceOracle.getPrice(address(0x0));

        uint256 valueOfCollateral =
            (collateral_ether[msg.sender] * priceOfEther) + (collateral_token[msg.sender] * priceOfReserveToken);
        uint256 valueOfBorrowing = priceOfBorrowing * _amount;
        uint256 valueOfCurrentDebt = priceOfReserveToken * debt_token[msg.sender];

        uint256 valueOfAllOfBorrwoing = valueOfBorrowing + valueOfCurrentDebt;

        // TODO: CHECK 담보 자산의 50% 만 빌릴 수 있음
        require(valueOfAllOfBorrwoing <= valueOfCollateral / 2, "Borrow amount exceeds 50% of collateral value.");
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "Insufficient vault balance.");

        debt_token[msg.sender] += _amount;
        total_collateral_token -= _amount;
        reserveToken.transfer(msg.sender, _amount);
    }

    function repay(address _token, uint256 _amount) external payable {
        // TODO: not fully implemented, bug-gy now
        require(debt_token[msg.sender] >= _amount, "you can't repay more than borrowed");

        uint256 originalDebt = debt_token[msg.sender];
        uint256 originalCollateralBalance = total_collateral_token;
        // IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        this.deposit(_token, _amount);
        require(originalCollateralBalance + originalDebt == total_collateral_token);
        debt_token[msg.sender] -= _amount;
    }
}

interface IPriceOracle {
    function setPrice(address token, uint256 price) external;
    function getPrice(address token) external returns (uint256);
}
