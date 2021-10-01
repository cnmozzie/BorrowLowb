// contracts/LowbVoucher.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
 
import "./IPancakePair.sol";
import "./IPancakeRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BorrowLowb {
    
    /* Inverse basis point. */
    uint public constant INVERSE_BASIS_POINT = 100000000000;
    uint public constant MAXIMUM_FEE = 100000;
    uint public commission = 2e18;
    uint public feePerBlock;
    uint totalDeposit;
    
    struct Record {
        address prevUser;
        address nextUser;
        uint lowbAmount;
        uint usdtAmount;
        uint startBlock;
        uint feePerBlock;
    }
    
    address public owner;
    address public routerAddress;
    address public lpAddress;
    address public usdtAddress;
    address public lowbAddress;
    address[] public usdtToLowbPath;
    
    mapping (address => uint) public balanceOf;
    mapping (address => Record) public recordOf;

    // Emitted events
    event Deposit(address indexed user, uint amount);
    event Withdraw(address indexed user, uint amount);
    event LowbBorrowed(address indexed user, uint lowbAmount, uint usdtAmount);
    event ReturnAllLowb(address indexed user, uint lowbAmount, uint usdtAmount, uint interestAmount);
    event AddUsdt(address indexed user, uint amount);
    event MoreLowbBorrowed(address indexed user, uint amount);
    event UsdtLocked(address indexed user, address indexed borrower, uint usdtAmount, uint risk);
    event BuyBackLowb(address indexed user, uint usdtAmount, uint lowbAmount, uint commission);

    constructor(address lpAddress_, address routerAddress_) {
        lpAddress = lpAddress_;
        routerAddress = routerAddress_;
        owner = msg.sender;
        IPancakePair pair = IPancakePair(lpAddress_);
        usdtAddress = pair.token0();
        lowbAddress = pair.token1();
        usdtToLowbPath.push(usdtAddress);
        usdtToLowbPath.push(lowbAddress);
    }

    function getInterestOf(address user) public view returns (uint) {
        return recordOf[user].lowbAmount * recordOf[user].feePerBlock * (block.number - recordOf[user].startBlock) / INVERSE_BASIS_POINT;
    }

    function getRiskNumberOf(address user) public view returns (uint) {
        uint lowbAmount = recordOf[user].lowbAmount + getInterestOf(user);
        uint usdtAmount = recordOf[user].usdtAmount;
        IPancakePair pair = IPancakePair(lpAddress);
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, ) = pair.getReserves();
        return reserve0 * lowbAmount / reserve1 * INVERSE_BASIS_POINT / usdtAmount;
    }

    function setFee(uint fee_) public {
        require(msg.sender == owner, "You are not admin");
        require(fee_ < MAXIMUM_FEE, "Fee to high");
        feePerBlock = fee_;
    }
    
    function deposit(uint amount) public {
        require(amount > 0, "You deposit nothing!");
        IERC20 token = IERC20(lowbAddress);
        require(token.transferFrom(msg.sender, address(this), amount), "Lowb transfer failed");
        balanceOf[msg.sender] +=  amount;
        totalDeposit += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint amount) public {
        require(amount <= balanceOf[msg.sender], "amount larger than the balance");  
        balanceOf[msg.sender] -= amount;
        IERC20 token = IERC20(lowbAddress);
        require(token.transfer(msg.sender, amount), "Lowb transfer failed");
        totalDeposit -= amount;
        emit Withdraw(msg.sender, amount);
    }

    function borrowLowb(uint lowbAmount, uint usdtAmount) public {
        require(lowbAmount > 0, "You borrow nothing!");
        require(usdtAmount >= 50e18, "Not enough usdt!");
        recordOf[msg.sender] = Record(address(0), address(0), lowbAmount, usdtAmount, block.number, feePerBlock);
        require(getRiskNumberOf(msg.sender) < INVERSE_BASIS_POINT * 90/100, "borrow to much lowb!");
        IERC20 lowb = IERC20(lowbAddress);
        IERC20 usdt = IERC20(usdtAddress);
        require(usdt.transferFrom(msg.sender, address(this), usdtAmount), "usdt transfer failed");
        require(lowb.transfer(msg.sender, lowbAmount), "lowb transfer failed");
        _addRecords(msg.sender);
        emit LowbBorrowed(msg.sender, lowbAmount, usdtAmount);
    }

    function addMoreUsdt(uint amount) public {
        require(amount > 0, "You add nothing!");
        IERC20 token = IERC20(usdtAddress);
        require(token.transferFrom(msg.sender, address(this), amount), "usdt transfer failed");
        recordOf[msg.sender].usdtAmount += amount;
        emit AddUsdt(msg.sender, amount);
    }

    function borrowMoreLowb(uint amount) public {
        require(amount > 0, "You borrow nothing!");
        uint interest = getInterestOf(msg.sender);
        _removeRecords(msg.sender);
        recordOf[msg.sender].lowbAmount += (amount + interest);
        require(getRiskNumberOf(msg.sender) < INVERSE_BASIS_POINT * 90/100, "borrow to much lowb!");
        _addRecords(msg.sender);
        IERC20 token = IERC20(lowbAddress);
        require(token.transfer(msg.sender, amount), "lowb transfer failed");
        recordOf[msg.sender].startBlock = block.number;
        emit MoreLowbBorrowed(msg.sender, amount);
    }

    function _addRecords(address newUser) private {
        uint price = recordOf[newUser].lowbAmount / recordOf[newUser].usdtAmount;
        address prevUser = address(0);
        address user = recordOf[prevUser].nextUser;
        while (user != address(0)) {
            if (price > recordOf[user].lowbAmount / recordOf[user].usdtAmount) {
                recordOf[user].prevUser = newUser;
                recordOf[newUser].nextUser = user;
                recordOf[newUser].prevUser = prevUser;
                recordOf[prevUser].nextUser = newUser;
                return;
            }
            prevUser = user;
            user = recordOf[user].nextUser;
        }
        recordOf[prevUser].nextUser = newUser;
        recordOf[newUser].prevUser = prevUser;
    }

    function _removeRecords(address user) private {
        address prevUser = recordOf[user].prevUser;
        address nextUser = recordOf[user].nextUser;
        recordOf[prevUser].nextUser = nextUser;
        recordOf[nextUser].prevUser = prevUser;
    }

    function _returnAllLowb(address user) private {
        IERC20 lowb = IERC20(lowbAddress);
        IERC20 usdt = IERC20(usdtAddress);
        uint interest = getInterestOf(user);
        emit ReturnAllLowb(user, recordOf[user].lowbAmount, recordOf[user].usdtAmount, interest);
        require(lowb.transferFrom(msg.sender, address(this), recordOf[user].lowbAmount + interest), "lowb transfer failed");
        require(usdt.transfer(msg.sender, recordOf[user].usdtAmount), "usdt transfer failed");
        _removeRecords(user);
        recordOf[user] = Record(address(0), address(0), 0, 0, 0, 0);
    }

    function returnAllLowb() public {
        require(recordOf[msg.sender].lowbAmount > 0, "You return nothing!");
        _returnAllLowb(msg.sender);
    }

    function forceReturnAllLowb(address user) public {
        require(getRiskNumberOf(user) > INVERSE_BASIS_POINT * 95/100, "cannot force return for now!");
        _returnAllLowb(user);
    }

    function lockUsdt(address user) public {
        require(user != address(0), "invaild user address");
        require(getRiskNumberOf(user) > INVERSE_BASIS_POINT * 95/100, "cannot lock usdt for now!");
        recordOf[address(0)].lowbAmount += (recordOf[user].lowbAmount + getInterestOf(user));
        recordOf[address(0)].usdtAmount += (recordOf[user].usdtAmount - commission);
        emit UsdtLocked(msg.sender, user, recordOf[user].usdtAmount, getRiskNumberOf(user));
        _removeRecords(user);
        recordOf[user] = Record(address(0), address(0), 0, 0, 0, 0);
        IERC20 usdt = IERC20(usdtAddress);
        require(usdt.transfer(msg.sender, commission), "usdt transfer failed");
    }

    function buyBackLowb(uint amount) public {
        require(amount > 0 && amount <= recordOf[address(0)].usdtAmount, "invaild user address");
        uint minLowbAmount = amount * recordOf[address(0)].lowbAmount / recordOf[address(0)].usdtAmount;
        uint lowbCommission = minLowbAmount / 100;
        IERC20 usdt = IERC20(usdtAddress);
        require(usdt.approve(routerAddress, amount), "approve usdt failed");
        IPancakeRouter01 router = IPancakeRouter01(routerAddress);
        router.swapExactTokensForTokens(amount, minLowbAmount+lowbCommission, usdtToLowbPath, address(this), block.timestamp+300);
        recordOf[address(0)].usdtAmount -= amount;
        recordOf[address(0)].lowbAmount -= minLowbAmount;
        IERC20 lowb = IERC20(lowbAddress);
        require(lowb.transfer(msg.sender, lowbCommission), "lowb transfer failed");
        emit BuyBackLowb(msg.sender, amount, minLowbAmount, lowbCommission);
    }

    function getRecords(address user, uint n) public view returns (Record[] memory) {
        require(n > 0, "Invalid record number");
        Record[] memory records = new Record[](n);
        Record memory record = recordOf[user];
        for (uint i=0; i<n; i++) {
            records[i] = record;
            if (record.nextUser == address(0)) {
                break;
            }
            else {
                record = recordOf[record.nextUser];
            }
        }
        return records;
    }

}