# servus - DRAFT

Servus serializer spec and example implementation(s)

* This is a WIP
* Spec is not yet done!

# Why ?

-- To clarify.

# Draft

> [servus]
> 
> The word may be used as a greeting, a parting salutation, or as both, depending on the region and context
> (https://en.wikipedia.org/wiki/Servus)

## Stateless (well, almost)


### Goals

* Be able to encode immediate values from -2 -> 100
* Be able to cache/reference values during (de)serialization
* Easy to implement
* General purpose 

### Details

* Optional Header, 1 byte: ZZ = version, RR = Reserved (multibyte header etc.)
    
```
Bits    7......0
        RRZZxxxY                -- TBD
        RRZZxxYx                Y = 0 UTF8, 1 = Other (assume ANSI)
        RRZZxYxx                Y = 0 Multibyte LE, 1 = Multibyte BE
        RRZZYxxx                Y = 0 No states, 1 = states might be used
```

* No header assumes: 00000000 => Version 0 (this document), UTF8 strings, LE Byte order

* Command Byte:
    * First byte should be interpreted as _unsigned char_!
    * **SPECIAL-CASE:** `SERVUS_SREF_START`
        * If this is the first byte to decode, this indicates the start of a small reftable < 32 items
        * Only valid if 0 < N < 32
        * The 0-COUNT in this case is considerd _reserved for future use_
  
* Stateless semantics:
    * `VAL`: (single) value
    * `CVAL`: compound value (self-reference allowed in reftable!)
    * `CMD`: command
    * `CONST`: constant

* User Types/Tags:
    * All user types are expected to add/remove exactly one or two elements to/from the current scope
    * The resulting item be used as an item for the current scope
    * e.g.:
        - we are deserializing a map
        - we've finishd parsing the key ("mykey")
        - we find a usertag
            - IF: we have an attached user tag handler for this tag-id
                - control flow is given to the user
                - user parses two elements
                    - another map
                    - a byte array
                - user constructs some data only they know from these inputs
            - user returns this object to the calling deserializer context
                - the item for key "mykey" would be the user defined object
          - ELSE: we do not have an attached user tag handler
              - create a new map/object array
              - parse item 0 to element 0
              - parse item 1 to element 1
        - when using strict mode throw an exception?

### Command byte broken down

```
    NAME                  TYPE                        SEMANTICS    following data in VALUES/bytes
========================= =========================== ============ ==========================================
  0 SERVUS_NULL           nil                         VAL          no bytes 
  1 SERVUS_TRUE           true                        VAL          no bytes 
  2 SERVUS_FALSE          false                       VAL          no bytes 
  3 SERVUS_FLOAT_32       float32                     VAL          4 bytes (float32 LE)
  4 SERVUS_FLOAT_64       float64                     VAL          8 bytes (float64 LE)
  5 SERVUS_INT_8          int8                        VAL          1 byte (int8)
  6 SERVUS_UINT_8         uint8                       VAL          1 byte (uint8)
  7 SERVUS_INT_16         int16                       VAL          2 bytes (int16 LE)
  8 SERVUS_UINT_16        uint16                      VAL          2 bytes (uint16 LE)
  9 SERVUS_INT_32         int32                       VAL          4 bytes (int32 LE)
 10 SERVUS_UINT_32        uint32                      VAL          4 bytes (uint32 LE)
 11 SERVUS_INT_64         int64                       VAL          8 bytes (int64 LE)
 12 SERVUS_UINT_64        uint64                      VAL          8 bytes (uint64 LE)
 13 SERVUS_BSTR_8         string/bytearray            VAL          1 len (uint8) + N < 2^8 bytes 
 14 SERVUS_BSTR_16        string/bytearray            VAL          2 len (uint16 LE) + N < 2^16 bytes 
 15 SERVUS_BSTR_32        string/bytearray            VAL          4 len (uint32 LE) + N < 2^32 bytes 
 16 SERVUS_MAP_8          map/obj                     CVAL         1 len (uint8) + N < 2^8 VALUES 
 17 SERVUS_MAP_16         map/obj                     CVAL         2 len (uint16 LE) + N < 2^16 VALUES 
 18 SERVUS_MAP_32         map/obj                     CVAL         4 len (uint32 LE) + N < 2^32 VALUES 
 19 SERVUS_ARR_8          object array                CVAL         1 len (uint8) + N < 2^8 VALUES 
 20 SERVUS_ARR_16         object array                CVAL         2 len (uint16 LE) + N < 2^16 VALUES 
 21 SERVUS_ARR_32         object array                CVAL         4 len (uint32 LE) + N < 2^32 VALUES     
 22 SERVUS_USERTAG1_8     user type 1                 VAL          1 byte ID + 1 VALUE
 23 SERVUS_USERTAG1_16    user type 1                 VAL          2 byte ID (uint16 LE) + 1 VALUES
 24 SERVUS_USERTAG1_32    user type 1                 VAL          4 byte ID (uint32 LE) + 1 VALUES
 25 SERVUS_USERTAG2_8     user type 2                 VAL          1 byte ID + 2 VALUES 
 26 SERVUS_USERTAG2_16    user type 2                 VAL          2 byte ID (uint16 LE) + 2 VALUES 
 27 SERVUS_USERTAG2_32    user type 2                 VAL          4 byte ID (uint32 LE) + 2 VALUES
 28 SERVUS_REF_8          ref                         VAL          1 u8 REF INDEX (1 byte)
 29 SERVUS_REF_16         ref                         VAL          1 u16 REF INDEX (2 bytes, LE)
 30 SERVUS_REFTAB_8       reftable                    CVAL         1 len (uint8) + N < 2^8 VALUES 
 31 SERVUS_REFTAB_16      reftable                    CVAL         2 len (uint16 LE) + N < 2^16 VALUES 
 32 SERVUS_RESERVED       -- reserved --
 33 SERVUS_HEADER         optional header             CMD          COMMAND: 1 byte
 34 SERVUS_STATE_8        stateful 8                  CMD          COMMAND: stateful command (1 byte)
 35 SERVUS_STATE_16       stateful 16                 CMD          COMMAND: stateful command (2 bytes LE)
 36 SERVUS_STATE_32       stateful 32                 CMD          COMMAND: stateful command (4 bytes LE)
 37 SERVUS_STATE_64       stateful 64                 CMD          COMMAND: stateful command (8 bytes LE)  
------------------------- --------------------------- ------------ ------------------------------------------
 38 SERVUS_SREF_START     short ref/reftable          VAL/CVAL     no bytes (VAL) / N < 32 VALUES (CVAL)
    SERVUS_SREF_COUNT                                 CONST(32)
 70 SERVUS_SBSTR_START    short string/bytearray      VAL          N < 32 bytes 
    SERVUS_SBSTR_COUNT                                CONST(32)
102 SERVUS_SMAP_START     short map                   VAL          N < 16 VALUES 
    SERVUS_SMAP_COUNT                                 CONST(16)
118 SERVUS_SARR_START     short array                 VAL          N < 16 VALUES 
    SERVUS_SARR_COUNT                                 CONST(16)
134 SERVUS_SUSER1_START   short user type 1           VAL          1 VALUES 
    SERVUS_SUSER1_COUNT                               CONST(8)
142 SERVUS_SUSER2_START   short user type 2           VAL          2 VALUES 
    SERVUS_SUSER2_COUNT                               CONST(8)
150 SERVUS_IMM_START      immediate ints -5 -> 100    CONST(150)   no bytes 
    SERVUS_IMM_OFFSET                                 CONST(-155)  no bytes 
------------------------- --------------------------- ------------ ------------------------------------------

All reserved values:
    SERVUS_RESERVED             always
    SERVUS_SREF_START(0)        as first byte of the packet

```

Stateful:
- for communication
- for multipart serialization (one artifact references others)
- TBD


