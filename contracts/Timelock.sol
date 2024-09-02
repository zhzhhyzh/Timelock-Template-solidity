// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

contract Timelock {
    address public owner;
    string public description;
    // Constant Variables
    // MIN_DELAY deposit.timestamp > block.timestamp + MIN_DELAY
    // MAX_DELAY deposit.timestamp , block.timestamp + MAX_DELAY
    // MAX_DELAY deposit.timestamp , block.timestamp + MAX_DELAY
    uint256 public constant MIN_DELAY = 10; // 10s
    uint256 public constant MAX_DELAY = 172800; // 2days =172800=86400s * 2
    uint256 public constant GRACE_PERIOD = 432000; // 5days =432000=86400s * 5

    function queue(
        address _target,
        bytes32 _depositId,
        string calldata _func
    ) external onlyOwner {
        Deposit memory deposit = depositIdToDeposit[_depositId];
        bytes32 txId = getTxId(_target, _depositId, _func);

        // Ensure that the deposit has not been queued yet
        require(isQueued(txId) == false, "AlreadyQueuedError");

        // ---|---------------|---------------------------|-------
        //  block       block + MIN_DELAY           block + MAX_DELAY

        // Ensure the timestamp is within the allowed range
        require(
            deposit.timestamp > block.timestamp + MIN_DELAY &&
                deposit.timestamp < block.timestamp + MAX_DELAY,
            "TimestampNotInRangeError"
        );
        // Queue the deposit for execution by txId
        queued[txId] = deposit;

        // Emit an event
        emit QueuedEvent(
            txId,
            _target,
            deposit.to,
            deposit.amount,
            _func,
            deposit.timestamp
        );
        // Free memory space
        delete deposit;
        delete txId;
    }

    function execute(
        address _target,
        bytes32 _depositId,
        string calldata _func
    ) external payable onlyOwner returns (bytes memory) {
        bytes32 txId = getTxId(_target, _depositId, _func);
        Deposit memory deposit = queued[txId];

        // Ensure the transaction is queued
        require(queued[txId].amount > 0, "NotQueuedError");

        // Ensure the delay has passed or been reached
        require(
            queued[txId].timestamp < block.timestamp,
            "TimestampNotPassedError"
        );

        // Ensure the grace period has not expired yet
        require(
            block.timestamp < queued[txId].timestamp + GRACE_PERIOD,
            "TimestampExpiredError"
        );

        // prepare data
        bytes memory data;
        data = abi.encodePacked(bytes4(keccak256(bytes(_func))), txId);

        // call target
        (bool ok, bytes memory res) = (deposit.to).call{value: deposit.amount}(
            data
        );
        require(ok, "TxFailedError");

        // Emit an event
        emit ExecutedTxEvent(
            txId,
            _target,
            deposit.to,
            deposit.amount,
            deposit.timestamp
        );

        // Free memory space
        delete queued[txId];
        delete deposit;
        delete data;

        // Return the receipt of the transaction
        return res;
    }

    function claim(bytes32 _depositId) external onlyOwner {
        (Deposit memory oneDeposit, uint256 index) = getOneDeposit(_depositId);

        // Ensure that the deposit has not been claimed yet
        require(
            oneDeposit.claimed == false &&
                depositIdToDeposit[_depositId].claimed == false,
            "This deposit has been claimed already"
        );

        // Update the claim field on the deposits mapping
        deposits[oneDeposit.from][index] = Deposit(
            _depositId,
            oneDeposit.description,
            oneDeposit.from,
            oneDeposit.to,
            oneDeposit.amount,
            oneDeposit.timestamp,
            true
        );
        // Update the claim field on the depositIdToDeposit mapping
        depositIdToDeposit[_depositId].claimed = true;

        // Free memory space
        delete oneDeposit;

        // Emit an event
        emit ClaimedDepositEvent(_depositId);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only Owner can execute this function");
        _;
    }

    // Ensures that only the timestamp passed meets the requirements
    modifier isValidTimestamp(uint256 _timestamp) {
        require(
            validTimestamp(_timestamp),
            "The timelock period has to be in the future"
        );
        _;
    }

    constructor(string memory _description, address _owner) {
        description = _description;
        owner = _owner;
    }

    // Enables contract to receive funds
    receive() external payable {}

    function getDepositTxId(
        string memory _description,
        address _from,
        address _to,
        uint256 _amount,
        uint256 _timestamp
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(_description, _from, _to, _amount, _timestamp)
            );
    }

    function validTimestamp(uint256 _timestamp) internal view returns (bool) {
        return (block.timestamp) < _timestamp;
    }

    function getDeposits() public view returns (Deposit[] memory) {
        return deposits[msg.sender];
    }

    function getOneDeposit(bytes32 _depositTxId)
        public
        view
        returns (Deposit memory deposit, uint256 index)
    {
        for (uint256 i = 0; i < deposits[msg.sender].length; i++) {
            if (deposits[msg.sender][i].depositId == _depositTxId)
                return (deposits[msg.sender][i], i);
        }
    }

    function fetchDeposit(address _user, bytes32 _depositTxId)
        internal
        view
        returns (Deposit memory deposit, uint256 index)
    {
        for (uint256 i = 0; i < deposits[_user].length; i++) {
            if (deposits[_user][i].depositId == _depositTxId)
                return (deposits[_user][i], i);
        }
    }

    function reimburseUser(address _user, uint256 _amount) internal {
        (bool sent, ) = payable(_user).call{value: _amount}("");
        require(sent, "Failed to send Ether");
    }

    function updateDeposit(
        bytes32 _depositId,
        string memory _description,
        address _to,
        uint256 _amount,
        uint256 _timestamp
    ) public payable isValidTimestamp(_timestamp) {
        (Deposit memory deposit, uint256 index) = getOneDeposit(_depositId);
        bytes32 depositId = getDepositTxId(
            _description,
            msg.sender,
            _to,
            _amount,
            _timestamp
        );
        require(_amount > 0, "AmountLowError");
        require(deposit.amount > 0, "NoDepositFoundError");

        if (_amount > deposit.amount) {
            // Ensure there is enough funds in the user account
            require(
                msg.sender.balance > (_amount - deposit.amount),
                "Balance low. Topup your account"
            );

            (bool sent, ) = payable(address(this)).call{
                value: _amount - deposit.amount
            }("");
            require(sent, "Failed to send Ether");
        } else if (_amount < deposit.amount) {
            reimburseUser(msg.sender, deposit.amount - _amount);
        }

        deposits[msg.sender][index] = Deposit(
            getDepositTxId(_description, msg.sender, _to, _amount, _timestamp),
            _description,
            msg.sender,
            _to,
            _amount,
            _timestamp,
            false
        );
        // Update depositId => Deposit Mapping
        require(
            depositIdToDeposit[deposit.depositId].amount > 0,
            "There is no deposit associated with this id"
        );

        // Delete old entry in the mapping
        delete depositIdToDeposit[deposit.depositId];

        // Update the mapping with new entry
        depositIdToDeposit[depositId] = Deposit(
            depositId,
            _description,
            msg.sender,
            _to,
            _amount,
            _timestamp,
            false
        );
        emit UpdatedDepositEvent(
            _description,
            msg.sender,
            _to,
            _amount,
            _timestamp
        );
    }

    function removeDepositByIndex(address _depositor, uint256 _index) internal {
        if (_index >= deposits[_depositor].length) return;

        deposits[_depositor][_index] = deposits[_depositor][
            deposits[_depositor].length - 1
        ];
        deposits[_depositor].pop();
    }

    struct Deposit {
        bytes32 depositId;
        string description;
        address from;
        address to;
        uint256 amount;
        uint256 timestamp;
        bool claimed;
    }

    // Maps an address to a list of Deposits
    mapping(address => Deposit[]) public deposits;

    // Maps a depositId to a Deposit
    mapping(bytes32 => Deposit) public depositIdToDeposit;

    // Maps a txId(Queued Tx) to a Deposit (tx id => queued)
    mapping(bytes32 => Deposit) public queued;
    // Events Declarations
    event DepositedFundsEvent(
        address indexed _from,
        address indexed _to,
        uint256 _amount,
        uint256 _timestamp
    );
    event ExecutedTxEvent(
        bytes32 indexed _txId,
        address indexed _target,
        address indexed _to,
        uint256 _amount,
        uint256 _timestamp
    );
    event UpdatedDepositEvent(
        string _description,
        address indexed _from,
        address indexed _to,
        uint256 _amount,
        uint256 _timestamp
    );
    event CanceledTxEvent(bytes32 indexed _txId);
    event QueuedEvent(
        bytes32 indexed _txId,
        address indexed _target,
        address indexed _to,
        uint256 _amount,
        string _func,
        uint256 _timestamp
    );
    event ClaimedDepositEvent(bytes32 indexed _depositId);

    function getTxId(
        address _target,
        bytes32 depositId,
        string calldata _func
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(_target, depositId, _func));
    }

    function isQueued(bytes32 _txId) public view returns (bool _isQueued) {
        if (queued[_txId].to != address(0)) return true;
    }

    function cancel(bytes32 _txId) external onlyOwner {
        require(isQueued(_txId) == true, "NotQueuedError");
        // require(queued[_txId].amount > 0, "NotQueuedError");
        Deposit memory deposit = queued[_txId];
        (, uint256 index) = getOneDeposit(deposit.depositId);
        removeDepositByIndex(deposit.from, index);

        // Reimburse the depositor
        (bool ok, ) = (deposit.from).call{value: deposit.amount}("");
        require(ok, "Reimbursement Error");

        // Clear the memory
        delete queued[_txId];
        delete deposit;
        delete index;

        // Emit the event
        emit CanceledTxEvent(_txId);
    }
}
