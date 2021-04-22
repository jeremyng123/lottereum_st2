pragma solidity >=0.5.0;

contract Lottereum {

    address payable public house;               // house of lottery
    uint256 public MIN_DEPOSIT;                 // min deposit
    uint256 public currDeposit;                 // current deposit required
    uint256 public changeDeposit;               // how much to change for successive/dishonest rounds
    uint256 public waitingTime;                 // how long the lottery should wait before payout (i.e., 5 mins)
    uint256[] public lotteryIDs;                // list of lotteryIDs
    mapping(uint256 => uint256) public lotteryIDIndex; // lotteryID => index
    mapping(uint256 => Lottery) public lotteries;      // lotteryID => lottery
    bool public isActive = true;                // active lottery
    enum State { 
      Created, Betted, Resolved, Paidout, Inactive        
    }

    struct Lottery {
        uint256 jackpot;                        // collected bets
        uint256 depositPot;                     // collected deposits
        uint256 deposit;                        // current deposit rate
        uint256 endTime;                        // start time + waitingTime
        uint256 playerCount;                    // total players
        bool isActive;                          // state of the lottery if now is not more than endtime
        mapping(address => Ticket) entries;     // player => ticket
        address payable[] honestPlayers;        // list of honestPlayers. To make this payable so that we can distribute the deposit of dishonest player to the honest punters
        bytes32[] userInputs;                   // list of reveals
        bytes32 combinedInput;                  // combined input randomization
        address payable winner;                 // winner
        State state;                            // the state of the lottery lottery
    }
    
    struct Ticket {
        uint256 betAmount;                      // input amount - deposit
        bytes32 inputHash;                      // hash of player input
        uint256 timestamp;                      // time of entry
    }

    event LogLottery(
        address _house,
        uint256 _MIN_DEPOSIT,
        uint256 _currDeposit,
        uint256 _changeDeposit,
        uint256 _waitingTime
    );

    event LogLotteryGame(
        uint256 indexed _lotteryID,
        uint256 _deposit,
        uint256 _endTime
    );

    event LogTicket(
        address _address,
        uint256 _lotteryID,
        uint256 _betAmount,
        uint256 _timestamp
    );

    event LogResolve(
        address indexed _address,
        uint256 indexed _lotteryID,
        bytes32 _userInput
    );

    event LogWinner(
        address indexed _address,
        uint256 indexed _lotteryID,
        uint256 _winnings,
        uint256 _time
    );

    constructor (
        uint256 _MIN_DEPOSIT,
        uint256 _currDeposit,
        uint256 _changeDeposit,
        uint256 _waitingTime
    ) 
        public 
    {
        require(_waitingTime >= 1 minutes, "Lottery length must be >= 60");
        house = msg.sender;
        MIN_DEPOSIT = _MIN_DEPOSIT;
        currDeposit = _currDeposit;
        changeDeposit = _changeDeposit;
        waitingTime = _waitingTime;
        emit LogLottery(
            house,
            MIN_DEPOSIT,
            currDeposit,
            changeDeposit,
            waitingTime
        );
    }

    modifier houseOnly() {
        require(msg.sender == house, "Only the lottery house can use this");
        _;
    }

    /* Phase 1 - Collect bets from buyTicket() calls */
    function startLottery() public {
        uint256 lotteryID = block.timestamp;
        Lottery storage lottery = lotteries[lotteryID]; // store the lottery in storage
        lotteryIDIndex[lotteryID] = lotteryIDs.length;  
        lotteryIDs.push(lotteryID);
        lottery.isActive = true;
        lottery.deposit = currDeposit;
        lottery.endTime = lotteryID + waitingTime;
        lottery.state = State.Created;
        emit LogLotteryGame(lotteryID, lottery.deposit, lottery.endTime);
    }

    function buyTicket(uint256 _lotteryID, bytes32 _userInput) public payable {
        Lottery storage lottery = lotteries[_lotteryID];
        // close lottery if exceed endTime on buyTicket attempt
        if (lottery.endTime < block.timestamp) { 
          lottery.isActive = false;
        }
        // only allow buyTicket if game is active
        require(lottery.isActive, "Buy-in period is over");
        // check if bet exceeds deposit amount
        require(msg.value > lottery.deposit, "Bet amount must exceed deposit");
        lottery.state = State.Betted; // now there are bets in the lottery
        uint256 bet = msg.value - lottery.deposit;
        lottery.depositPot += lottery.deposit;
        lottery.jackpot += bet;
        lottery.playerCount++;
        // hash _userInput
        lottery.entries[msg.sender] = Ticket(
            bet,
            keccak256(abi.encode(_userInput)),
            block.timestamp
        );
        emit LogTicket(msg.sender, _lotteryID, bet, block.timestamp);
    }

    /* Phase 2 - Collect initial userInputs for honesty check */
    function resolveLottery (uint256 _lotteryID, bytes32 _userInput) public { 
        Lottery storage lottery = lotteries[_lotteryID];
        // close lottery if exceed endTime on resolveLottery attempt
        if (lottery.endTime < block.timestamp) { 
          lottery.isActive = false; 
        }
        // only allow resolving if lottery is closed
        require(!lottery.isActive, "Buy-in period is not over yet");
        // hash _userInput
        bytes32 inputHash = keccak256(abi.encode(_userInput));
        // check for honest player
        if (inputHash == lottery.entries[msg.sender].inputHash) {
            // use _userInput in "randomizer"
            lottery.combinedInput = mergeHash(lottery.combinedInput, _userInput);
            // track _userInputs
            lottery.userInputs.push(_userInput);
            // add honest player to list
            lottery.honestPlayers.push(msg.sender);
            emit LogResolve(msg.sender, _lotteryID, _userInput);
        }
        lottery.state = State.Resolved;
    }

    /* Phase 3 - Select winner, distribute refunds, send payout */
    function getPayout(uint256 _lotteryID) public {
        Lottery storage lottery = lotteries[_lotteryID];
        // only allow payout if lottery has resolved
        require(lottery.state == State.Resolved, "Lottery resolution is not over yet");
        // we verify that winner has not been resolved
        if (lottery.winner == address(0)) {
            // increase honesty deposit if lottery has dishonest punters
            if (lottery.honestPlayers.length < lottery.playerCount) {
                currDeposit += changeDeposit;
            } else if (lottery.playerCount > 0) {
                // decrease deposit if all punters are honest
                  currDeposit -= changeDeposit;
                  if (currDeposit < MIN_DEPOSIT) {
                      currDeposit = MIN_DEPOSIT;
                  }

            }
            if (lottery.honestPlayers.length == 0) {
                // deposit and jackpot go to house if no honest punters
                house.transfer(lottery.depositPot);
                house.transfer(lottery.jackpot);
            } else {
                // distribute deposit
                uint256 share = lottery.depositPot / lottery.honestPlayers.length;
                for (uint256 i = 0; i < lottery.honestPlayers.length; i++) {
                    lottery.honestPlayers[i].transfer(share);
                    lottery.depositPot -= share;
                }
                // remainder of deposit goes to house
                house.transfer(lottery.depositPot);

                /* Choose winner */
                uint256 winnerIndex = (
                    (uint256(lottery.combinedInput) % lottery.honestPlayers.length)
                );
                lottery.winner = lottery.honestPlayers[winnerIndex];
                lottery.winner.transfer(lottery.jackpot);
                emit LogWinner(lottery.winner, _lotteryID, lottery.jackpot, block.timestamp);
            }
            closeLottery(_lotteryID);
        }
    }

    function closeLottery(uint256 _lotteryID) internal {
        // find index of _lotteryID in lotteryIDs
        uint256 index = lotteryIDIndex[_lotteryID];
        if (lotteryIDs.length > 1) {
            // update index of tail lotteryID
            lotteryIDIndex[lotteryIDs[lotteryIDs.length-1]] = index;
            // copy tail of lotteryIDs to replace index
            lotteryIDs[index] = lotteryIDs[lotteryIDs.length-1];
        }
        // shorten tail and cleanup for gas refund
        lotteryIDs.length--;
        delete lotteryIDIndex[_lotteryID];
        delete lotteries[_lotteryID];
    }

    function mergeHash(bytes32 b1, bytes32 b2) internal pure returns (bytes32){
        bytes memory merged = new bytes(64);
        uint256 idx = 0;
        // zip the inputs
        for (uint256 i = 0; i < 32; i++) {
            merged[idx] = b1[i];
            idx++;
            merged[idx] = b2[i];
            idx++;
        }
        // hash the merged inputs
        return keccak256(merged);
    }


    function showLotteryCount() public view returns (uint256) {
        return lotteryIDs.length;
    }

    function toggleActive() public houseOnly {
        isActive = !isActive;
    }

    function kill() public houseOnly {
        selfdestruct(house);
    }

}
