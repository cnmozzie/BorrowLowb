// contracts/LowbVoucher.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
 
import "./IPancakePair.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BorrowLowb {
    
    /* Inverse basis point. */
    uint public constant INVERSE_BASIS_POINT = 100000000;
    uint public constant MAXIMUM_FEE = 1000;
    uint public feePerBlock;
    uint totalInterest;
    
    struct Record {
        address prevUser;
        address nextUser;
        uint lowbAmount;
        uint usdtAmount;
        uint startBlock;
    }
    
    address public owner;
    address public lpAddress;
    address public usdtAddress;
    address public lowbAddress;
    address public riskAddress;
    
    mapping (address => uint) public balanceOf;
    mapping (address => Record) public recordOf;

    // Emitted events
    event Deposit(address indexed user, uint amount);
    event Withdraw(address indexed user, uint amount);
    event LowbBorrowed(address indexed user, uint lowbAmount, uint usdtAmount);
    event ReturnAllLowb(address indexed user, uint lowbAmount, uint usdtAmount, uint interestAmount);
    event AddUsdt(address indexed user, uint amount);
    event MoreLowbBorrowed(address indexed user, uint amount);

    constructor(address lpAddress_) {
        lpAddress = lpAddress_;
        owner = msg.sender;
        IPancakePair pair = IPancakePair(lpAddress_);
        usdtAddress = pair.token0();
        lowbAddress = pair.token1();
    }

    function getInterestOf(address user) public view returns (uint) {
        return recordOf[user].lowbAmount * feePerBlock * (block.number - recordOf[user].startBlock) / INVERSE_BASIS_POINT;
    }

    function getRiskNumberOf(address user) public view returns (uint) {
        uint lowbAmount = recordOf[user].lowbAmount;
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
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint amount) public {
        require(amount <= balanceOf[msg.sender], "amount larger than the balance");  
        balanceOf[msg.sender] -= amount;
        IERC20 token = IERC20(lowbAddress);
        require(token.transfer(msg.sender, amount), "Lowb transfer failed");
        emit Withdraw(msg.sender, amount);
    }

    function borrowLowb(uint lowbAmount, uint usdtAmount) public {
        require(lowbAmount > 0, "You borrow nothing!");
        require(usdtAmount >= 50e18, "Not enough usdt!");
        recordOf[msg.sender] = Record(address(0), address(0), lowbAmount, usdtAmount, block.number);
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
        totalInterest += interest;
        recordOf[msg.sender].startBlock = block.number;
        emit MoreLowbBorrowed(msg.sender, amount);
    }

    function _addRecords(address newUser) private {
        uint price = recordOf[newUser].lowbAmount / recordOf[newUser].usdtAmount;
        address user = recordOf[address(0)].nextUser;
        while (user != address(0)) {
            if (price >= recordOf[user].lowbAmount / recordOf[user].usdtAmount) {
                address prevUser = recordOf[user].prevUser;
                recordOf[user].prevUser = user;
                recordOf[newUser].nextUser = user;
                recordOf[newUser].prevUser = prevUser;
                recordOf[prevUser].nextUser = newUser;
                return;
            }
            user = recordOf[user].nextUser;
        }
        recordOf[user].nextUser = newUser;
        recordOf[newUser].prevUser = user;
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
        totalInterest += interest;
        _removeRecords(user);
        recordOf[user] = Record(address(0), address(0), 0, 0, 0);
    }

    function returnAllLowb() public {
        require(recordOf[msg.sender].lowbAmount > 0, "You return nothing!");
        _returnAllLowb(msg.sender);
    }

    function forceReturnAllLowb(address user) public {
        require(getRiskNumberOf(user) > INVERSE_BASIS_POINT * 95/100, "borrow to much lowb!");
        _returnAllLowb(user);
    }

}