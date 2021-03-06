pragma solidity ^0.5.0;

interface PhoenixTokenTestnetInterface {
    function transfer(address _to, uint256 _amount) external returns (bool success);
    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool success);
    function doTransfer(address _from, address _to, uint _amount) external;
    function balanceOf(address _owner) external view returns (uint256 balance);
    function approve(address _spender, uint256 _amount) external returns (bool success);
    function approveAndCall(address _spender, uint256 _value, bytes calldata _extraData) external returns (bool success);
    function burn(uint256 _value) external;
    function allowance(address _owner, address _spender) external view returns (uint256 remaining);
    function totalSupply() external view returns (uint);
    function setPhoenixAuthenticationAddress(address _phoenixAuthentication) external;
    function authenticate(uint _value, uint _challenge, uint _partnerId) external;
    function setBalances(address[] calldata _addressList, uint[] calldata _amounts) external;
    function getMoreTokens() external;
}

interface IdentityRegistryInterface {
    function isSigned(address _address, bytes32 messageHash, uint8 v, bytes32 r, bytes32 s)
        external pure returns (bool);
    function identityExists(uint ein) external view returns (bool);
    function hasIdentity(address _address) external view returns (bool);
    function getEIN(address _address) external view returns (uint ein);
    function isAssociatedAddressFor(uint ein, address _address) external view returns (bool);
    function isProviderFor(uint ein, address provider) external view returns (bool);
    function isResolverFor(uint ein, address resolver) external view returns (bool);
    function getIdentity(uint ein) external view returns (
        address recoveryAddress,
        address[] memory associatedAddresses, address[] memory providers, address[] memory resolvers
    );
    function createIdentity(address recoveryAddress, address[] calldata providers, address[] calldata resolvers)
        external returns (uint ein);
    function createIdentityDelegated(
        address recoveryAddress, address associatedAddress, address[] calldata providers, address[] calldata resolvers,
        uint8 v, bytes32 r, bytes32 s, uint timestamp
    ) external returns (uint ein);
    function addAssociatedAddress(
        address approvingAddress, address addressToAdd, uint8 v, bytes32 r, bytes32 s, uint timestamp
    ) external;
    function addAssociatedAddressDelegated(
        address approvingAddress, address addressToAdd,
        uint8[2] calldata v, bytes32[2] calldata r, bytes32[2] calldata s, uint[2] calldata timestamp
    ) external;
    function removeAssociatedAddress() external;
    function removeAssociatedAddressDelegated(address addressToRemove, uint8 v, bytes32 r, bytes32 s, uint timestamp)
        external;
    function addProviders(address[] calldata providers) external;
    function addProvidersFor(uint ein, address[] calldata providers) external;
    function removeProviders(address[] calldata providers) external;
    function removeProvidersFor(uint ein, address[] calldata providers) external;
    function addResolvers(address[] calldata resolvers) external;
    function addResolversFor(uint ein, address[] calldata resolvers) external;
    function removeResolvers(address[] calldata resolvers) external;
    function removeResolversFor(uint ein, address[] calldata resolvers) external;
    function triggerRecoveryAddressChange(address newRecoveryAddress) external;
    function triggerRecoveryAddressChangeFor(uint ein, address newRecoveryAddress) external;
    function triggerRecovery(uint ein, address newAssociatedAddress, uint8 v, bytes32 r, bytes32 s, uint timestamp)
        external;
    function triggerDestruction(
        uint ein, address[] calldata firstChunk, address[] calldata lastChunk, bool resetResolvers
    ) external;
}

contract Dispute {
    event DisputeGenerated(uint256 indexed id, uint256 indexed orderId, string reason);

    struct DisputeItem {
        uint256 id;
        uint256 orderId;
        uint256 createdAt;
        address refundReceiver;
        string reason;
        string counterReason;
        bytes32 state; // Either pending, countered or resolved. Where pending indicates "waiting for the seller to respond", countered means "the seller has responded" and resolved is "the dispute has been resolved"
    }

    // DisputeItem id => dispute struct
    mapping(uint256 => DisputeItem) public disputeById;
    DisputeItem[] public disputes;
    Store public store;
    address[] public operators;
    address public owner;

    modifier onlyOperator {
        require(operatorExists(msg.sender), 'Only a valid operator can run this function');
        _;
    }

    /// @notice To setup the store address
    /// @param _store The address of the store contract that will be used in this contract
    constructor(address _store) public {
        store = Store(_store);
        owner = msg.sender;
        operators.push(msg.sender);
    }

    /// @notice To dispute an order for the specified reason as a buyer
    /// @param _id The order id to dispute
    /// @param _reason The string indicating why the buyer is disputing this order
    function disputeOrder(uint256 _id, string memory _reason) public {
        require(bytes(_reason).length > 0, 'The reason for disputing the order cannot be empty');
        DisputeItem memory d = disputeById[_id];
        require(d.state == 0, 'The order state must be empty');
        (uint256 id, uint256 addressId, uint256 productId, uint256 date, uint256 buyer, address addressBuyer, bytes32 state) = store.orderById(_id);
        require(now - date < 15 days, 'You can only dispute an order that has not been closed yet');
        uint256 ein = IdentityRegistryInterface(store.identityRegistry()).getEIN(msg.sender);
        require(buyer == ein, 'Only the buyer can dispute his order');
        uint256 disputeId = disputes.length;
        d = DisputeItem(disputeId, _id, now, msg.sender, _reason, '', 'pending');
        disputes.push(d);
        disputeById[disputeId] = d;
        emit DisputeGenerated(disputeId, _id, _reason);
    }

    /// @notice To respond to a dispute as a seller
    /// @param _disputeId The id of the dispute to respond to
    /// @param _counterReason The reason for countering the argument of the buyer
    function counterDispute(uint256 _disputeId, string memory _counterReason) public {
        require(bytes(_counterReason).length > 0, 'The counter reason must be set');
        DisputeItem memory d = disputeById[_disputeId];
        require(d.state == 'pending', 'The order state must be pending');
        (uint256 id, uint256 addressId, uint256 productId, uint256 date, uint256 buyer, address addressBuyer, bytes32 state) = store.orderById(d.orderId);
        require(now - date < 15 days, 'You can only dispute an order that has not been closed yet');

        uint256 ein = IdentityRegistryInterface(store.identityRegistry()).getEIN(msg.sender);
        require(store.getProductEinOwner(productId) == ein, 'Only the seller can counter dispute this order');
        d.counterReason = _counterReason;
        d.state = 'countered';
        disputeById[_disputeId] = d;
        for(uint256 i = 0; i < disputes.length; i++) {
            if(disputes[i].id == _disputeId) {
                disputes[i] = d;
                break;
            }
        }
    }

    /// @notice To resolve a dispute and pay the buyer from the seller's approved balance
    /// @param _disputeId The id of the dispute to resolve
    /// @param _isBuyerWinner If the winner is the buyer or not to perform the transfer
    function resolveDispute(uint256 _disputeId, bool _isBuyerWinner) public onlyOperator {
        DisputeItem memory d = disputeById[_disputeId];
        require(bytes(d.counterReason).length > 0, 'The counter reason must be set');
        require(d.state == 'countered', 'The order state must be countered');
        (uint256 id, uint256 addressId, uint256 productId, uint256 date, uint256 buyer, address addressBuyer, bytes32 state) = store.orderById(d.orderId);
        require(now - date < 15 days, 'You can only dispute an order that has not been closed yet');

        d.state = 'resolved';
        disputeById[_disputeId] = d;
        for(uint256 i = 0; i < disputes.length; i++) {
            if(disputes[i].id == _disputeId) {
                disputes[i] = d;
                break;
            }
        }

        if(_isBuyerWinner) {
            // Pay the product price to the buyer as a refund
            PhoenixTokenTestnetInterface(store.token()).transferFrom(address(store), addressBuyer, store.getProductPrice(productId));
        }
    }

    /// @notice To add or delete operators by the owner
    /// @param _user A valid address to add or remove from the list of operators
    /// @param _isRemoved Whether you want to add or remove this operator
    function setOperator(address _user, bool _isRemoved) public {
        require(msg.sender == owner, 'Only the owner can add operators');
        if(_isRemoved) {
            for(uint256 i = 0; i < operators.length; i++) {
                if(operators[i] == _user) {
                    address lastElement = operators[operators.length - 1];
                    operators[i] = lastElement;
                    operators.length--;
                }
            }
        } else {
            operators.push(_user);
        }
    }

    /// @notice To check if an operator exists
    /// @param _operator The address of the operator to check
    /// @return bool Whether he's a valid operator or not
    function operatorExists(address _operator) internal view returns(bool) {
        for(uint256 i = 0; i < operators.length; i++) {
            if(_operator == operators[i]) {
                return true;
            }
        }
        return false;
    }
}


contract Store {
    struct Product {
        uint256 id;
        bytes32 sku;
        string title;
        string description;
        uint256 date;
        uint256 einOwner; // EIN owner
        address owner;
        uint256 price;
        string image;
        bytes32[] attributes;
        bytes32[] attributeValues;
        uint256 quantity;
        uint256 barcode;
    }
    struct Order {
        uint256 id; // Unique order ID
        uint256 addressId;
        uint256 productId;
        uint256 date;
        uint256 buyer; // EIN buyer
        address addressBuyer;
        bytes32 state; // Either 'pending', 'sent', 'completed' completed means that the seller has sent the product and he's extracted the payment
    }
    struct Address {
        string nameSurname;
        string direction;
        bytes32 city;
        bytes32 stateRegion;
        uint256 postalCode;
        bytes32 country;
        uint256 phone;
    }
    struct Inventory {
        uint256 id;
        string name;
        bytes32[] skus;
    }

    // Seller ein => orders
    mapping(uint256 => Order[]) public pendingOrders; // The products waiting to be fulfilled
    // Buyer ein => orders
    mapping(uint256 => Order[]) public completedOrders;
    // Product id => product
    mapping(uint256 => Product) public productById;
    // Order id => order struct
    mapping(uint256 => Order) public orderById;
    // Id => address
    mapping(uint256 => Address) public addressById;
    Product[] public products;
    Inventory[] public inventories;
    address public owner;
    uint256 public lastId;
    uint256 public lastOrderId;
    uint256 public lastAddressId;
    address public token;
    address public identityRegistry;
    address public disputeContract;

    /// @notice To setup the address of the ERC-721 token to use for this contract
    /// @param _token The token address
    constructor(address _token, address _identityRegistry) public {
        owner = msg.sender;
        token = _token;
        identityRegistry = _identityRegistry;
    }

    /// @notice To set the address of the dispute contract for making disputes
    /// @param _dispute The dispute address
    function setDisputeAddress(address _dispute) public {
        require(msg.sender == owner, 'Only the owner can set the dispute contract');
        require(disputeContract == address(0), 'You cannot change the address of the contract once set');
        require(_dispute != address(0), 'The dispute address cannot be empty');
        disputeContract = _dispute;
    }

    /// @notice To publish a product as a seller
    /// @param _title The title of the product
    /// @param _description The description of the product
    /// @param _price The price of the product in ETH
    /// @param _image The image URL of the product
    function publishProduct(string memory _title, bytes32 _sku, string memory _description, uint256 _price, string memory _image, bytes32[] memory _attributes, bytes32[] memory _attributeValues, uint256 _quantity, uint256 _barcode) public {
        require(bytes(_title).length > 0, 'The title cannot be empty');
        require(bytes(_description).length > 0, 'The description cannot be empty');
        require(_price > 0, 'The price cannot be empty');
        require(bytes(_image).length > 0, 'The image cannot be empty');
        require(IdentityRegistryInterface(identityRegistry).hasIdentity(msg.sender), 'You must have an EIN associated with your Ethereum account to add a product');

        Product memory p = Product(lastId, _sku, _title, _description, now, IdentityRegistryInterface(identityRegistry).getEIN(msg.sender), msg.sender, _price, _image, _attributes, _attributeValues, _quantity, _barcode);
        products.push(p);
        productById[lastId] = p;
        lastId++;
    }

    /// @notice To create an inventory in which to store product skus
    /// @param _name The name of the inventory
    /// @param _skus The array of skus to add to the inventory
    function createInventory(string memory _name, bytes32[] memory _skus) public {
        require(bytes(_name).length > 0, 'The name must be set');
        require(_skus.length > 0, 'There must be at least one sku for this inventory');
        Inventory memory inv = Inventory(inventories.length, _name, _skus);
        inventories.push(inv);
    }

    /// @notice To buy a new product, note that the seller must authorize this contract to manage the token
    /// @param _id The id of the product to buy
    /// @param _nameSurname The name and surname of the buyer
    // / @param _lineOneDire The first line for the user address
    // / @param _lineTwoDirection The second, optional user address line
    /// @param _city Buyer's city
    /// @param _stateRegion The state or region where the buyer lives
    /// @param _postalCode The postal code of his location
    /// @param _country Buyer's country
    /// @param _phone The optional phone number for the shipping company
    /// The payment in PHNX is made automatically by making a transferFrom after approving the right amount of tokens using the product price
    function buyProduct(uint256 _id, string memory _nameSurname, string memory _direction, bytes32 _city, bytes32 _stateRegion, uint256 _postalCode, bytes32 _country, uint256 _phone) public {
        // The line 2 address and phone are optional, the rest are mandatory
        require(bytes(_nameSurname).length > 0, 'The name and surname must be set');
        require(bytes(_direction).length > 0, 'The line one direction must be set');
        require(_city.length > 0, 'The city must be set');
        require(_stateRegion.length > 0, 'The state or region must be set');
        require(_postalCode > 0, 'The postal code must be set');
        require(_country > 0, 'The country must be set');
        require(IdentityRegistryInterface(identityRegistry).hasIdentity(msg.sender), 'You must have an EIN associated with your Ethereum account to purchase the product');

        uint256 ein = IdentityRegistryInterface(identityRegistry).getEIN(msg.sender);
        Product memory p = productById[_id];
        require(bytes(p.title).length > 0, 'The product must exist to be purchased');
        require(PhoenixTokenTestnetInterface(token).allowance(msg.sender, address(this)) >= p.price, 'You must have enough PHNX tokens approved to purchase this product');
        Address memory newAddress = Address(_nameSurname, _direction, _city, _stateRegion, _postalCode, _country, _phone);
        Order memory newOrder = Order(lastOrderId, lastAddressId, _id, now, ein, msg.sender, 'pending');

        // Update the quantity of remaining products
        if(p.quantity > 0) {
            p.quantity--;
            productById[_id] = p;
            // Update the products array
            for(uint256 i = 0; i < products.length; i++) {
                if(products[i].id == p.id) {
                    products[i] = p;
                    break;
                }
            }
        }

        pendingOrders[ein].push(newOrder);
        orderById[_id] = newOrder;
        addressById[lastAddressId] = newAddress;
        // TODO remember that the payment has been done to the store contract and not the seller yet
        PhoenixTokenTestnetInterface(token).transferFrom(msg.sender, address(this), p.price); // Pay the product price to this contract
        PhoenixTokenTestnetInterface(token).approve(disputeContract, p.price);
        lastOrderId++;
        lastAddressId++;
    }

    /// @notice To receive payments for sellers that sold a product, each product must be checked independently. You can only do it after the product has been marked as sent and the
    /// @param _orderId The ID of the order that you want to mark as completed and receie the payment
    function receivePayment(uint256 _orderId) public {
        Order memory order = orderById[_orderId];
        Product memory p = productById[order.productId];
        uint256 ein = IdentityRegistryInterface(identityRegistry).getEIN(msg.sender);
        require(p.einOwner == ein, 'Only the seller can receive the payment of the order');
        require(order.state == 'sent', 'The order must be marked as sent to receive the payment');
        require(now - order.date >= 15 days, 'You can only retrieve the payment after 15 days');

        order.state = 'completed';
        // Delete the seller order from the array of pending orders
        for(uint256 i = 0; i < pendingOrders[p.einOwner].length; i++) {
            if(pendingOrders[p.einOwner][i].id == _orderId) {
                Order memory lastElement = orderById[pendingOrders[p.einOwner].length - 1];
                pendingOrders[p.einOwner][i] = lastElement;
                pendingOrders[p.einOwner].length--;
            }
        }
        completedOrders[order.buyer].push(order);
        orderById[_orderId] = order;
        PhoenixTokenTestnetInterface(token).transfer(p.owner, p.price);
    }

    /// @notice To mark an order as sent
    /// @param _id The id of the order to mark as sent and completed
    function markOrderSent(uint256 _id) public {
        Order memory order = orderById[_id];
        Product memory product = productById[order.productId];
        require(IdentityRegistryInterface(identityRegistry).hasIdentity(msg.sender), 'You must have an EIN associated with your Ethereum account to mark the order as completed');
        uint256 ein = IdentityRegistryInterface(identityRegistry).getEIN(msg.sender);
        require(product.einOwner == ein, 'Only the seller can mark the order as sent');
        order.state = 'sent';
        orderById[_id] = order;
    }

    /// @notice To get the ein owner of a product for the dispute contract
    /// @param _id The id of the product
    /// @return Returns the ein owner
    function getProductEinOwner(uint256 _id) public view returns(uint256) {
        return productById[_id].einOwner;
    }

    /// @notice To get the price of a product for the dispute contract
    /// @param _id The id of the product
    /// @return Returns the price
    function getProductPrice(uint256 _id) public view returns(uint256) {
        return productById[_id].price;
    }
}
