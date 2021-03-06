pragma solidity ^0.4.21;

// VersionConsole with additional testing features
contract TestVersionConsole {

  // Storage address to read from - readMulti and readSingle functions read from this address
  address public app_storage;

  // Keeps track of the last storage return
  bytes32[] public last_storage_event;

  // Constructor - set storage address
  function TestVersionConsole(address _storage) public {
    app_storage = _storage;
  }

  // Change storage address
  function newStorage(address _new_storage) public {
    app_storage = _new_storage;
  }

  // Get the last chunk of data stored with getBuffer
  function getLastStorage() public view returns (bytes32[] stored) {
    return last_storage_event;
  }

  /// PROVIDER STORAGE ///

  // Provider namespace - all app and version storage is seeded to a provider
  // [PROVIDERS][provider_id]
  bytes32 public constant PROVIDERS = keccak256("registry_providers");

  /// APPLICATION STORAGE ///

  // Application namespace - all app info and version storage is mapped here
  // [PROVIDERS][provider_id][APPS][app_name]
  bytes32 public constant APPS = keccak256("apps");

  // Application version list location - (bytes32 array)
  // [PROVIDERS][provider_id][APPS][app_name][APP_VERSIONS_LIST] = bytes32[] version_names
  bytes32 public constant APP_VERSIONS_LIST = keccak256("app_versions_list");

  // Application storage address location - address
  // [PROVIDERS][provider_id][APPS][app_name][APP_STORAGE_IMPL] = address app_default_storage_addr
  bytes32 public constant APP_STORAGE_IMPL = keccak256("app_storage_impl");

  /// VERSION STORAGE ///

  // Version namespace - all version and function info is mapped here
  // [PROVIDERS][provider_id][APPS][app_hash][VERSIONS]
  bytes32 public constant VERSIONS = keccak256("versions");

  // Version description location - (bytes array)
  // [PROVIDERS][provider_id][APPS][app_hash][VERSIONS][ver_hash][VER_DESC] = bytes description
  bytes32 public constant VER_DESC = keccak256("ver_desc");

  // Version "is finalized" location - whether a version is ready for use (all intended functions implemented)
  // [PROVIDERS][provider_id][APPS][app_hash][VERSIONS][ver_name][VER_IS_FINALIZED] = bool is_finalized
  bytes32 public constant VER_IS_FINALIZED = keccak256("ver_is_finalized");

  // Version storage address - if nonzero, overrides application-specified storage address
  // [PROVIDERS][provider_id][APPS][app_hash][VERSIONS][ver_name][VER_PERMISSIONED] = address version_storage_addr
  bytes32 public constant VER_STORAGE_IMPL = keccak256("ver_storage_impl");

  // Version initialization address location - contains the version's 'init' function
  // [PROVIDERS][provider_id][APPS][app_hash][VERSIONS][ver_name][VER_INIT_ADDR] = address ver_init_addr
  bytes32 public constant VER_INIT_ADDR = keccak256("ver_init_addr");

  // Version initialization function signature - called when initializing an instance of a version
  // [PROVIDERS][provider_id][APPS][app_hash][VERSIONS][ver_name][VER_INIT_SIG] = bytes4 init_signature
  bytes32 public constant VER_INIT_SIG = keccak256("ver_init_signature");

  // Version 'init' function description location - bytes of a version's initialization function description
  // [PROVIDERS][provider_id][APPS][app_hash][VERSIONS][ver_name][VER_INIT_DESC] = bytes description
  bytes32 public constant VER_INIT_DESC = keccak256("ver_init_desc");

  /// FUNCTION SELECTORS ///

  // Function selector for storage 'readMulti'
  // readMulti(bytes32 exec_id, bytes32[] locations)
  bytes4 public constant RD_MULTI = bytes4(keccak256("readMulti(bytes32,bytes32[])"));

  /// EXCEPTION MESSAGES ///

  bytes32 public constant ERR_UNKNOWN_CONTEXT = bytes32("UnknownContext"); // Malformed '_context' array
  bytes32 public constant ERR_INSUFFICIENT_PERMISSIONS = bytes32("InsufficientPermissions"); // Action not allowed
  bytes32 public constant ERR_READ_FAILED = bytes32("StorageReadFailed"); // Read from storage address failed

  /// FUNCTIONS ///

  /*
  Registers a version of an application under the sender's provider id

  @param _app: The name of the application under which the version will be registered
  @param _ver_name: The name of the version to register
  @param _ver_storage: The storage address to use for this version. If left empty, storage uses application default address
  @param _ver_desc: The decsription of the version
  @param _context: The execution context for this application - a 96-byte array containing (in order):
    1. Application execution id
    2. Original script sender (address, padded to 32 bytes)
    3. Wei amount sent with transaction to storage
  @return store_data: A formatted storage request - first 64 bytes designate a forwarding address (and amount) for any wei sent
  */
  function registerVersion(bytes32 _app, bytes32 _ver_name, address _ver_storage, bytes _ver_desc, bytes _context) public
  returns (bytes32[] store_data) {
    // Ensure input is correctly formatted
    require(_context.length == 96);
    require(_app != bytes32(0) && _ver_name != bytes32(0) && _ver_desc.length > 0);

    address provider;
    bytes32 exec_id;

    // Parse context array and get sender address and execution id
    (exec_id, provider, ) = parse(_context);

    // Place app storage location in calldata
    bytes32 temp = keccak256(keccak256(provider), PROVIDERS); // Use a temporary var to get app base storage location
    temp = keccak256(keccak256(_app), keccak256(APPS, temp));

    /// Ensure application is already registered, and that the version name is unique.
    /// Additionally, get the app's default storage address, and the app's version list length -

    // Create 'readMulti' calldata buffer in memory
    uint ptr = cdBuff(RD_MULTI);
    // Place exec id, data read offset, and read size to calldata
    cdPush(ptr, exec_id);
    cdPush(ptr, 0x40);
    cdPush(ptr, 4);
    cdPush(ptr, temp); // Push app base storage location to read buffer
    cdPush(ptr, keccak256(keccak256(_ver_name), keccak256(VERSIONS, temp))); // Push version base storage location to buffer
    cdPush(ptr, keccak256(APP_STORAGE_IMPL, temp)); // App default storage address location
    cdPush(ptr, keccak256(APP_VERSIONS_LIST, temp)); // App version list storage location
    // Read from storage and store return in buffer
    bytes32[] memory read_values = readMulti(ptr);
    // Check returned values -
    if (
      read_values[0] == bytes32(0) // Application does not exist
      || read_values[1] != bytes32(0) // Version name already exists
    ) {
      triggerException(ERR_INSUFFICIENT_PERMISSIONS);
    }

    // If passed in version storage address is zero, set version storage address to returned app default storage address
    if (_ver_storage == address(0))
      _ver_storage = address(read_values[2]);

    // Get app version list length
    uint num_versions = uint(read_values[3]);

    /// App is registered, and version name is unique - store version information:

    // Overwrite previous read buffer with storage return buffer
    stOverwrite(ptr);
    // Push payment destination and amount to buffer
    stPush(ptr, 0);
    stPush(ptr, 0);
    // Increment app version list length, and push new version name to the end of that list
    stPush(ptr, keccak256(APP_VERSIONS_LIST, temp));
    stPush(ptr, bytes32(num_versions + 1));
    // End of app version list - 32 * num_versions + base_location
    stPush(ptr, bytes32(32 * (1 + num_versions) + uint(keccak256(APP_VERSIONS_LIST, temp))));
    stPush(ptr, _ver_name);
    // Place version name in version base storage location
    temp = keccak256(keccak256(_ver_name), keccak256(VERSIONS, temp));
    stPush(ptr, temp);
    stPush(ptr, _ver_name);
    // Place version storage address in version storage address location
    stPush(ptr, keccak256(VER_STORAGE_IMPL, temp));
    stPush(ptr, bytes32(_ver_storage));
    // Push version description to storage buffer
    // Get version description storage location
    temp = keccak256(VER_DESC, temp);
    stPushBytes(ptr, temp, _ver_desc);

    // Get bytes32[] representation of storage buffer
    store_data = getBuffer(ptr);
  }

  /*
  Finalizes a registered version by providing instance initialization information

  @param _app: The name of the application under which the version is registered
  @param _ver_name: The name of the version to finalize
  @param _ver_init_address: The address which contains the version's initialization function
  @param _init_sig: The function signature for the version's initialization function
  @param _init_description: A description of the version's initialization function and parameters
  @param _context: The execution context for this application - a 96-byte array containing (in order):
    1. Application execution id
    2. Original script sender (address, padded to 32 bytes)
    3. Wei amount sent with transaction to storage
  @return store_data: A formatted storage request - first 64 bytes designate a forwarding address (and amount) for any wei sent
  */
  function finalizeVersion(bytes32 _app, bytes32 _ver_name, address _ver_init_address, bytes4 _init_sig, bytes _init_description, bytes _context) public
  returns (bytes32[] store_data) {
    // Ensure input is correctly formatted
    require(_context.length == 96);
    require(_app != bytes32(0) && _ver_name != bytes32(0));
    require(_ver_init_address != address(0) && _init_sig != bytes4(0) && _init_description.length > 0);

    address provider;
    bytes32 exec_id;

    // Parse context array and get sender address and execution id
    (exec_id, provider, ) = parse(_context);

    /// Ensure application and version are registered, and that the version is not already finalized -

    // Create 'readMulti' calldata buffer in memory
    uint ptr = cdBuff(RD_MULTI);
    // Place exec id, data read offset, and read size in buffer
    cdPush(ptr, exec_id);
    cdPush(ptr, 0x40);
    cdPush(ptr, 3);
    // Push app base storage, version base storage, and version finalization status storage locations to buffer
    // Get app base storage -
    bytes32 temp = keccak256(keccak256(provider), PROVIDERS);
    temp = keccak256(keccak256(_app), keccak256(APPS, temp));
    cdPush(ptr, temp);
    // Get version base storage -
    temp = keccak256(keccak256(_ver_name), keccak256(VERSIONS, temp));
    cdPush(ptr, temp);
    cdPush(ptr, keccak256(VER_IS_FINALIZED, temp));
    // Read from storage and store return in buffer
    bytes32[] memory read_values = readMulti(ptr);
    // Check returned values -
    if (
      read_values[0] == bytes32(0) // Application does not exist
      || read_values[1] == bytes32(0) // Version does not exist
      || read_values[2] != bytes32(0) // Version already finalized
    ) {
      triggerException(ERR_INSUFFICIENT_PERMISSIONS);
    }

    /// App and version are registered, and version is ready to be finalized -

    // Overwrite previous read buffer with storage buffer
    stOverwrite(ptr);
    // Push payment destination and value (0, 0) to storage buffer
    stPush(ptr, 0);
    stPush(ptr, 0);
    // Push new version finalization status to buffer
    stPush(ptr, keccak256(VER_IS_FINALIZED, temp));
    stPush(ptr, bytes32(1));
    // Push version initialization address to buffer
    stPush(ptr, keccak256(VER_INIT_ADDR, temp));
    stPush(ptr, bytes32(_ver_init_address));
    // Push version initialization function selector to buffer
    stPush(ptr, keccak256(VER_INIT_SIG, temp));
    stPush(ptr, _init_sig);
    // Add version initialization fucntion description to buffer
    stPushBytes(ptr, keccak256(VER_INIT_DESC, temp), _init_description);

    // Get bytes32[] representation of storage buffer
    store_data = getBuffer(ptr);
  }

  /*
  Creates a new return data storage buffer at the position given by the pointer. Does not update free memory

  @param _ptr: A pointer to the location where the buffer will be created
  */
  function stOverwrite(uint _ptr) internal pure {
    assembly {
      // Simple set the initial length - 0
      mstore(_ptr, 0)
    }
  }

  /*
  Pushes a value to the end of a storage return buffer, and updates the length

  @param _ptr: A pointer to the start of the buffer
  @param _val: The value to push to the buffer
  */
  function stPush(uint _ptr, bytes32 _val) internal pure {
    assembly {
      // Get end of buffer - 32 bytes plus the length stored at the pointer
      let len := add(0x20, mload(_ptr))
      // Push value to end of buffer (overwrites memory - be careful!)
      mstore(add(_ptr, len), _val)
      // Increment buffer length
      mstore(_ptr, len)
      // If the free-memory pointer does not point beyond the buffer's current size, update it
      if lt(mload(0x40), add(add(0x20, _ptr), len)) {
        mstore(0x40, add(add(0x40, _ptr), len)) // Ensure free memory pointer points to the beginning of a memory slot
      }
    }
  }

  /*
  Pushes a bytes array to the storage buffer, including its length. Uses the given base location to get the storage locations for each
  index in the array

  @param _ptr: A pointer to the start of the buffer
  @param _base_location: The storage location of the length of the array
  @param _arr: The bytes array to push
  */
  function stPushBytes(uint _ptr, bytes32 _base_location, bytes _arr) internal pure {
    assembly {
      // Get end of buffer - 32 bytes plus the length stored at the pointer
      let len := add(0x20, mload(_ptr))
      // Loop over bytes array, and push each value to storage buffer, while incrementing the current storage location
      let offset := 0x00
      for { } lt(offset, add(0x20, mload(_arr))) { offset := add(0x20, offset) } {
        // Push incremented location to buffer
        mstore(add(add(len, mul(2, offset)), _ptr), add(offset, _base_location))
        // Push bytes array chunk to buffer
        mstore(add(add(add(0x20, len), mul(2, offset)), _ptr), mload(add(offset, _arr)))
      }
      // Increment buffer length
      mstore(_ptr, add(mul(2, offset), mload(_ptr)))
      // If the free-memory pointer does not point beyond the buffer's current size, update it
      if lt(mload(0x40), add(add(0x20, _ptr), mload(_ptr))) {
        mstore(0x40, add(add(0x40, _ptr), mload(_ptr))) // Ensure free memory pointer points to the beginning of a memory slot
      }
    }
  }

  /*
  Returns the bytes32[] stored at the buffer

  @param _ptr: A pointer to the location in memory where the calldata for the call is stored
  @return store_data: The return values, which will be stored
  */
  function getBuffer(uint _ptr) internal returns (bytes32[] store_data){
    assembly {
      // If the size stored at the pointer is not evenly divislble into 32-byte segments, this was improperly constructed
      if gt(mod(mload(_ptr), 0x20), 0) { revert (0, 0) }
      mstore(_ptr, div(mload(_ptr), 0x20))
      store_data := _ptr
    }
    last_storage_event = store_data;
  }

  /*
  Creates a calldata buffer in memory with the given function selector

  @param _selector: The function selector to push to the first location in the buffer
  @return ptr: The location in memory where the length of the buffer is stored - elements stored consecutively after this location
  */
  function cdBuff(bytes4 _selector) internal pure returns (uint ptr) {
    assembly {
      // Get buffer location - free memory
      ptr := mload(0x40)
      // Place initial length (4 bytes) in buffer
      mstore(ptr, 0x04)
      // Place function selector in buffer, after length
      mstore(add(0x20, ptr), _selector)
      // Update free-memory pointer - it's important to note that this is not actually free memory, if the pointer is meant to expand
      mstore(0x40, add(0x40, ptr))
    }
  }

  /*
  Pushes a value to the end of a calldata buffer, and updates the length

  @param _ptr: A pointer to the start of the buffer
  @param _val: The value to push to the buffer
  */
  function cdPush(uint _ptr, bytes32 _val) internal pure {
    assembly {
      // Get end of buffer - 32 bytes plus the length stored at the pointer
      let len := add(0x20, mload(_ptr))
      // Push value to end of buffer (overwrites memory - be careful!)
      mstore(add(_ptr, len), _val)
      // Increment buffer length
      mstore(_ptr, len)
      // If the free-memory pointer does not point beyond the buffer's current size, update it
      if lt(mload(0x40), add(add(0x20, _ptr), len)) {
        mstore(0x40, add(add(0x2c, _ptr), len)) // Ensure free memory pointer points to the beginning of a memory slot
      }
    }
  }

  /*
  Executes a 'readMulti' function call, given a pointer to a calldata buffer
  Test version reads from app storage address

  @param _ptr: A pointer to the location in memory where the calldata for the call is stored
  @return read_values: The values read from storage
  */
  function readMulti(uint _ptr) internal view returns (bytes32[] read_values) {
    bool success;
    address _storage = app_storage;
    assembly {
      // Minimum length for 'readMulti' - 1 location is 0x84
      if lt(mload(_ptr), 0x84) { revert (0, 0) }
      // Read from storage
      success := staticcall(gas, _storage, add(0x20, _ptr), mload(_ptr), 0, 0)
      // If call succeed, get return information
      if gt(success, 0) {
        // Ensure data will not be copied beyond the pointer
        if gt(sub(returndatasize, 0x20), mload(_ptr)) { revert (0, 0) }
        // Copy returned data to pointer, overwriting it in the process
        // Copies returndatasize, but ignores the initial read offset so that the bytes32[] returned in the read is sitting directly at the pointer
        returndatacopy(_ptr, 0x20, sub(returndatasize, 0x20))
        // Set return bytes32[] to pointer, which should now have the stored length of the returned array
        read_values := _ptr
      }
    }
    if (!success)
      triggerException(ERR_READ_FAILED);
  }

  /*
  Reverts state changes, but passes message back to caller

  @param _message: The message to return to the caller
  */
  function triggerException(bytes32 _message) internal pure {
    assembly {
      mstore(0, _message)
      revert(0, 0x20)
    }
  }


  // Parses context array and returns execution id, sender address, and sent wei amount
  function parse(bytes _context) internal pure returns (bytes32 exec_id, address from, uint wei_sent) {
    assembly {
      exec_id := mload(add(0x20, _context))
      from := mload(add(0x40, _context))
      wei_sent := mload(add(0x60, _context))
    }
    // Ensure sender and exec id are valid
    if (from == address(0) || exec_id == bytes32(0))
      triggerException(ERR_UNKNOWN_CONTEXT);
  }
}
