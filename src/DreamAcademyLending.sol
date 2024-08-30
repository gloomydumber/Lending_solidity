// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import "./FixedPointMathLib.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// - ETH를 담보로 사용해서 USDC를 빌리고 빌려줄 수 있는 서비스를 구현하세요.
// - 이자율은 24시간에 0.1% (복리), Loan To Value (LTV)는 50%, liquidation threshold는 75%로 하고 담보 가격 정보는 “참고코드"를 참고해 생성한 컨트랙트에서 갖고 오세요.
// - 필요한 기능들은 다음과 같습니다. Deposit (ETH, USDC 입금), Borrow (담보만큼 USDC 대출), Repay (대출 상환), Liquidate (담보를 청산하여 USDC 확보)
// - 청산 방법은 다양하기 때문에 조사 후 bad debt을 최소화에 가장 적합하다고 생각하는 방식을 적용하고 그 이유를 쓰세요.
// - 실제 토큰을 사용하지 않고 컨트랙트 생성자의 인자로 받은 주소들을 토큰의 주소로 간주합니다.
// - 주요 기능 인터페이스는 아래를 참고해 만드시면 됩니다.

contract DreamAcademyLending {
    using FixedPointMathLib for uint256;

    struct UserBalance {
        uint256 collateral;
        uint256 balance;
        uint256 debt;
        uint256 reserves;
        uint256 lastUpdated;
    }

    struct ProtocolStatus {
        uint256 accumulatedInterest;
        uint256 prevAccumulatedInterest;
        address[] activeUsers;
    }

    uint256 constant BLOCKS_PER_DAY = 7200;
    uint256 constant INTEREST_RATE = 1e15; // 0.1 % per 1 DAY

    address usdc;
    IPriceOracle priceOracle;
    ProtocolStatus protocolStatus;

    mapping(address => UserBalance) user;

    constructor(IPriceOracle _priceOralce, address _usdc) {
        priceOracle = _priceOralce;
        usdc = _usdc;
    }

    function initializeLendingProtocol(address _usdc) external payable {
        IERC20(_usdc).transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address tokenAddress, uint256 amount) external payable {
        if (tokenAddress == address(0)) {
            require(msg.value == amount, "Not Adequate Ether Sent");
            user[msg.sender].collateral += amount;
        } else if (tokenAddress == usdc) {
            require(IERC20(usdc).balanceOf(msg.sender) >= amount, "Not Enough USDC Balance");
            updateProtocolByDeposit();
            IERC20(usdc).transferFrom(msg.sender, address(this), amount);
            user[msg.sender].balance += amount;
            protocolStatus.activeUsers.push(msg.sender);
        }
    }

    function borrow(address tokenAddress, uint256 amount) external payable {
        require(tokenAddress == usdc, "Only USDC Borrowable");

        uint256 currentUnitPriceOfCollateral = priceOracle.getPrice(address(0)) / 1e18;
        uint256 userCollateral = user[msg.sender].collateral;
        uint256 usdcValueOfCollateral = userCollateral * currentUnitPriceOfCollateral;
        uint256 userDebt = user[msg.sender].debt; // in USDC

        require(usdcValueOfCollateral / 2 >= amount + userDebt, "Not Enough Collateral to Borrow that amount");

        user[msg.sender].debt += amount;
        user[msg.sender].lastUpdated = block.number;
        protocolStatus.activeUsers.push(msg.sender);

        IERC20(usdc).transfer(msg.sender, amount);
    }

    function repay(address tokenAddress, uint256 amount) external payable {
        require(tokenAddress == usdc, "Only USDC Repayable");

        if (amount > user[msg.sender].debt) {
            amount = user[msg.sender].debt;
        }

        calculateInterest(msg.sender);
        IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        user[msg.sender].debt -= amount;
    }

    function liquidate(address userAddress, address tokenAddress, uint256 amount) external {
        require(amount > 0, "Not Enough Amount to Liquidate");
        require(msg.sender != userAddress, "You are not eligible to Liquidate");
        require(tokenAddress == usdc, "Only USDC Accepted");

        uint256 priceOfEther = priceOracle.getPrice(address(0));
        uint256 priceOfUSDCoin = priceOracle.getPrice(usdc);
        require(
            ((priceOfEther * user[userAddress].collateral * 75) / 100 < user[userAddress].debt * (priceOfUSDCoin))
                && (user[userAddress].debt * 25) / 100 >= amount,
            "Not Enough Threshold to Liquidate"
        );

        uint256 ethCompensation = amount * user[userAddress].collateral / (user[userAddress].debt);
        user[userAddress].debt -= amount;
        ERC20(usdc).transferFrom(msg.sender, address(this), amount);
        payable(msg.sender).transfer(ethCompensation);
    }

    function withdraw(address tokenAddress, uint256 amount) external {
        require(tokenAddress == address(0) || tokenAddress == usdc, "Not Supporting Token");
        require(amount > 0, "Not Adequate withdraw amount");
        calculateInterest(msg.sender);
        if (tokenAddress == address(0)) {
            if (user[msg.sender].debt == 0) {
                payable(msg.sender).transfer(amount);
                user[msg.sender].collateral -= amount;
            } else {
                uint256 priceOfEther = priceOracle.getPrice(address(0));
                uint256 priceOfUSDCoin = priceOracle.getPrice(usdc);
                require(
                    ((priceOfEther * ((user[msg.sender].collateral - (amount)))) * 75) / 100
                        > user[msg.sender].debt * (priceOfUSDCoin),
                    "Withdraw amount exceeds allowed collateral ratio"
                );
                payable(msg.sender).transfer(amount);
                user[msg.sender].collateral -= amount;
            }
        } else {
            amount = getAccruedSupplyAmount(tokenAddress) / 1e18 * 1e18;
            user[msg.sender].balance += amount - user[msg.sender].balance;
            IERC20(usdc).transfer(msg.sender, amount);
            user[msg.sender].balance -= amount;
        }
    }

    function getAccruedSupplyAmount(address _token) public returns (uint256) {
        updateProtocolByWithdrawOrFetching();
        uint256 totalProtocolBalance = IERC20(_token).balanceOf(address(this));
        uint256 userBalance = user[msg.sender].balance;
        uint256 userReserves = user[msg.sender].reserves;
        uint256 accruedInterest = (protocolStatus.accumulatedInterest - (protocolStatus.prevAccumulatedInterest))
            * (userBalance) / (totalProtocolBalance);
        uint256 accruedSupply = userBalance + (userReserves) + (accruedInterest);
        return accruedSupply;
    }

    function updateProtocolByDeposit() internal {
        uint256 activeUserLength = protocolStatus.activeUsers.length;
        uint256 totalProtocolBalance = IERC20(usdc).balanceOf(address(this));
        uint256 totalVolumeOfInterest = protocolStatus.accumulatedInterest;

        for (uint256 i = 0; i < activeUserLength; ++i) {
            address userAddress = protocolStatus.activeUsers[i];
            uint256 userReserves = totalVolumeOfInterest * user[userAddress].balance / totalProtocolBalance;
            user[userAddress].reserves = userReserves;
        }

        protocolStatus.prevAccumulatedInterest = protocolStatus.accumulatedInterest;
    }

    function updateProtocolByWithdrawOrFetching() internal {
        uint256 activeUserLength = protocolStatus.activeUsers.length;
        uint256 totalVolumeOfInterest = protocolStatus.accumulatedInterest;

        for (uint256 i = 0; i < activeUserLength; ++i) {
            address userAddress = protocolStatus.activeUsers[i];
            totalVolumeOfInterest += calculateInterest(userAddress);
        }

        protocolStatus.accumulatedInterest = totalVolumeOfInterest;
    }

    function _getCompoundInterest(uint256 p, uint256 r, uint256 n) internal pure returns (uint256) {
        uint256 rate = FixedPointMathLib.divWadUp(r, 1e18) + FixedPointMathLib.WAD;
        return FixedPointMathLib.mulWadUp(p, rate._ratePow(n, FixedPointMathLib.WAD));
    }

    function calculateInterest(address _userAddress) internal returns (uint256) {
        uint256 elapsed = block.number - user[_userAddress].lastUpdated;
        uint256 dayElapsed = elapsed / BLOCKS_PER_DAY;
        uint256 dayElapsedMod = elapsed % BLOCKS_PER_DAY;
        uint256 currentDebt = user[_userAddress].debt;

        uint256 accumulatedTotalDebt = _getCompoundInterest(currentDebt, INTEREST_RATE, dayElapsed);
        if (dayElapsedMod != 0) {
            accumulatedTotalDebt += (
                _getCompoundInterest(accumulatedTotalDebt, INTEREST_RATE, 1) - (accumulatedTotalDebt)
            ) * (dayElapsedMod) / (BLOCKS_PER_DAY);
        }

        uint256 addedDebt = accumulatedTotalDebt - (currentDebt);
        user[_userAddress].debt = accumulatedTotalDebt;
        user[_userAddress].lastUpdated = block.number;

        return addedDebt;
    }
}

interface IPriceOracle {
    function setPrice(address token, uint256 price) external;
    function getPrice(address token) external returns (uint256);
}
