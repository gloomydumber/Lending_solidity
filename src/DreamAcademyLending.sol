// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract DreamAcademyLending {
    IPriceOracle priceOracle;
    IERC20 reserveToken;

    uint256 public total_collateral_token;
    uint256 public total_collateral_ether;

    uint256 public loanInterestRate;
    uint256 public denominatorForLoanInterestRate;

    uint256 public depositInterestRate1;
    uint256 public depositInterestRate2;
    uint256 public denominatorForDepositInterestRate;

    mapping(address => uint256) collateral_ether;
    mapping(address => uint256) collateral_token;
    mapping(address => uint256) debt_token;
    mapping(address => uint256) public lastInterestAccrual;
    mapping(address => uint256) public lastSupplyInterestAccrual;
    mapping(address => uint256) public accruedSupplyInterest;

    constructor(IPriceOracle _priceOracle, address _reserveToken) {
        priceOracle = _priceOracle;
        reserveToken = IERC20(_reserveToken);
        loanInterestRate = 1; // 1 for 0.001%, 500 for 5%
        denominatorForLoanInterestRate = 10000;

        // bug: weired metrics are given for interests rates
        depositInterestRate1 = 3670500; // 3671000
        depositInterestRate2 = 7520000; // 7520000
        denominatorForDepositInterestRate = 1e18;
    }

    function initializeLendingProtocol(address _reserveToken) external payable {
        reserveToken = IERC20(_reserveToken);
        IERC20(_reserveToken).transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address _token, uint256 _amount) external payable {
        accrueSupplyInterest(msg.sender);

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

        lastSupplyInterestAccrual[msg.sender] = block.number;
    }

    function borrow(address _token, uint256 _amount) external {
        accrueInterest(msg.sender);

        uint256 priceOfBorrowing = priceOracle.getPrice(_token);
        uint256 priceOfReserveToken = priceOracle.getPrice(address(reserveToken));
        uint256 priceOfEther = priceOracle.getPrice(address(0x0));

        uint256 valueOfCollateral =
            (collateral_ether[msg.sender] * priceOfEther) + (collateral_token[msg.sender] * priceOfReserveToken);
        uint256 valueOfBorrowing = priceOfBorrowing * _amount;
        uint256 valueOfCurrentDebt = priceOfBorrowing * debt_token[msg.sender];

        uint256 valueOfAllOfBorrowing = valueOfBorrowing + valueOfCurrentDebt;

        // TODO: CHECK 담보 자산의 50% 만 빌릴 수 있음
        require(valueOfAllOfBorrowing <= (valueOfCollateral) / 2, "Borrow amount exceeds 50% of collateral value.");
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "Insufficient vault balance.");

        debt_token[msg.sender] += _amount;
        total_collateral_token -= _amount;
        IERC20(_token).transfer(msg.sender, _amount);
    }

    function repay(address _token, uint256 _amount) external payable {
        accrueInterest(msg.sender);

        require(debt_token[msg.sender] >= _amount, "you can't repay more than borrowed");
        require(IERC20(_token).balanceOf(msg.sender) >= _amount, "Insufficient user balance.");

        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        debt_token[msg.sender] -= _amount;
    }

    function withdraw(address _token, uint256 _amount) external {
        accrueInterest(msg.sender);
        accrueSupplyInterest(msg.sender);

        uint256 priceOfReserveToken = priceOracle.getPrice(address(reserveToken));
        uint256 priceOfEther = priceOracle.getPrice(address(0x0));

        uint256 valueOfCollateralBefore;
        if (_token == address(0x0)) {
            valueOfCollateralBefore =
                (collateral_ether[msg.sender] * priceOfEther) + (collateral_token[msg.sender] * priceOfReserveToken);
        } else {
            valueOfCollateralBefore = (collateral_ether[msg.sender] * priceOfEther)
                + (collateral_token[msg.sender] * priceOracle.getPrice(_token));
        }

        uint256 currentDebtValue = debt_token[msg.sender] * priceOfReserveToken;

        // TODO: CHECK 출금 후에도 담보 자산이 빌린자산의 75%를 보장해야함
        require(
            valueOfCollateralBefore - _amount * (_token == address(0x0) ? priceOfEther : priceOracle.getPrice(_token))
                >= (currentDebtValue * 100) / 75,
            "Withdraw amount exceeds allowed collateral ratio."
        );

        if (_token == address(0x0)) {
            require(collateral_ether[msg.sender] >= _amount, "you don't have enough ETH value to withdraw.");
            collateral_ether[msg.sender] -= _amount;
            total_collateral_ether -= _amount;
            (bool success,) = msg.sender.call{value: _amount}("");
            require(success, "ETH withdraw failed.");
        } else {
            require(collateral_token[msg.sender] >= _amount, "you don't have enough token value to withdraw.");
            collateral_token[msg.sender] -= _amount;
            total_collateral_token -= _amount;
            IERC20(_token).transfer(msg.sender, _amount);
        }

        lastSupplyInterestAccrual[msg.sender] = block.number;
    }

    function accrueInterest(address borrower) internal {
        uint256 blockElapsed = block.number - lastInterestAccrual[borrower];
        uint256 principal = debt_token[borrower];

        if (principal > 0 && blockElapsed > 0) {
            for (uint256 i = 0; i < blockElapsed; i++) {
                uint256 interestAccrued = (principal * loanInterestRate) / denominatorForLoanInterestRate;
                principal += interestAccrued;
            }

            debt_token[borrower] = principal;
        }

        lastInterestAccrual[borrower] = block.number;
    }

    function accrueSupplyInterest(address _token) internal {
        uint256 lastAccrual = lastSupplyInterestAccrual[msg.sender];
        uint256 blockElapsed = block.number - lastAccrual;
        uint256 principal = debt_token[msg.sender] > 0 ? 0 : collateral_token[msg.sender];
        uint256 interestAccrued = 0;

        if (principal > 0 && blockElapsed > 0) {
            if (lastAccrual < 7200000 && block.number > 7200000) {
                uint256 blocksAtRate1 = 7200000 - lastAccrual;
                interestAccrued +=
                    (principal * depositInterestRate1 * blocksAtRate1) / denominatorForDepositInterestRate;

                principal += interestAccrued;

                uint256 blocksAtRate2 = block.number - 7200000;
                interestAccrued +=
                    (principal * depositInterestRate2 * blocksAtRate2) / denominatorForDepositInterestRate;
            } else if (block.number <= 7200000) {
                interestAccrued += (principal * depositInterestRate1 * blockElapsed) / denominatorForDepositInterestRate;
            } else {
                interestAccrued += (principal * depositInterestRate2 * blockElapsed) / denominatorForDepositInterestRate;
            }

            collateral_token[msg.sender] += interestAccrued;
        }

        lastSupplyInterestAccrual[msg.sender] = block.number;
    }

    function getAccruedSupplyAmount(address _token) public view returns (uint256) {
        uint256 lastAccrual = lastSupplyInterestAccrual[msg.sender];
        uint256 blockElapsed = block.number - lastAccrual;
        uint256 principal = debt_token[msg.sender] > 0 ? 0 : collateral_token[msg.sender];
        uint256 interestAccrued = 0;

        if (principal > 0 && blockElapsed > 0) {
            if (lastAccrual < 7200000 && block.number > 7200000) {
                uint256 blocksAtRate1 = 7200000 - lastAccrual;
                interestAccrued +=
                    (principal * depositInterestRate1 * blocksAtRate1) / denominatorForDepositInterestRate;

                principal += interestAccrued;

                uint256 blocksAtRate2 = block.number - 7200000;
                interestAccrued +=
                    (principal * depositInterestRate2 * blocksAtRate2) / denominatorForDepositInterestRate;
            } else if (block.number <= 7200000) {
                interestAccrued += (principal * depositInterestRate1 * blockElapsed) / denominatorForDepositInterestRate;
            } else {
                interestAccrued += (principal * depositInterestRate2 * blockElapsed) / denominatorForDepositInterestRate;
            }
        }
        console.log(collateral_token[msg.sender] + interestAccrued);
        return collateral_token[msg.sender] + interestAccrued;
    }
}

interface IPriceOracle {
    function setPrice(address token, uint256 price) external;
    function getPrice(address token) external returns (uint256);
}
