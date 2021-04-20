# servus - DRAFT

Servus serializer spec and example implementation(s)

* This is a WIP
* Spec is not yet done!

# Why ?

* Like messagepack
```lua
    {compact = true, schema = 0}

    => 18b
    => l:schema\155;compact\001
```

* But slightly different
```lua
    {compact = true, schema = 0, no = "schema"}
    
    => 24b
    => \018\165m;compact\001:schema\1556no\017
```
* Mandatory xkcd

  
![https://xkcd.com/927/](https://imgs.xkcd.com/comics/standards.png)
https://xkcd.com/927/

-- Todo: clarify.

# Draft

> [servus]
> 
> The word may be used as a greeting, a parting salutation, or as both, depending on the region and context
> (https://en.wikipedia.org/wiki/Servus)

## Stateless (well, almost)


### Goals

* Be able to encode immediate values from -2 -> 100
* Be able to cache/reference values during (de)serialization
* Have clearly defined extension points for
  * The spec
  * The encoder/decoders
* Easy to implement
* General purpose 

### Maybe goals
* Have schemas

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

* Control Byte:
    * First byte should be interpreted as _unsigned char_!
    * **SPECIAL-CASE:** `REF/REFT`
        * If the first byte to decode is a `REF/REFT` byte, this indicates that references are used
        * In this case `REFT` semantics apply and the data should be interpreted as an array of references
        * The 0-length short table `REFT` (`SERVUS_S_REF_00`) is considerd _reserved for future use and should not be used_
        * In any later occurence of `REF/REFT` control bytes, they should be considered as references to data
  
* Stateless semantics:
    * `VAL`: (single) value
    * `CVAL`: compound value (self-references allowed)
    * `CMD`: a command which must no be included in value counts
    * `CONST`: constant
    * `REF/REFT`: a reference or a reference table
    * `_RES`: reserved, ignore this for now

* User Types/Tags:
    * All user types are expected to add/remove exactly one or two elements to/from the current scope
    * The resulting item is to be used as an item for the current scope
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

### Control byte broken down

```
                      Cluster
                            |
Label        Byte value     |   Type/interpreted value      Semantics
===============================================================================       
SERVUS_NULL           0     A   nil                         VAL
SERVUS_TRUE           1     A   true                        VAL
SERVUS_FALSE          2     A   false                       VAL
SERVUS_RESERVED       3         -- reserved --               _RES
SERVUS_INT_8          4     B   int8                        VAL
SERVUS_INT_16         5     B   int16                       VAL
SERVUS_INT_32         6     B   int32                       VAL
SERVUS_INT_64         7     B   int64                       VAL
SERVUS_UINT_8         8     B   uint8                       VAL
SERVUS_UINT_16        9     B   uint16                      VAL
SERVUS_UINT_32       10     B   uint32                      VAL
SERVUS_UINT_64       11     B   uint64                      VAL
SERVUS_FLOAT_32      12     B   float32                     VAL
SERVUS_FLOAT_64      13     B   float64                     VAL
SERVUS_REF_8         14     C   ref/reftable                REF/REFT
SERVUS_REF_16        15     C   ref/reftable                REF/REFT
SERVUS_REF_32        16     C   ref/reftable                REF/REFT
SERVUS_S_REF_00      17     C   short ref/reftable          REF/REFT
SERVUS_S_REF_31      48     C   short ref/reftable          REF/REFT
SERVUS_BSTR_8        49     D   string/bytearray            VAL
SERVUS_BSTR_16       50     D   string/bytearray            VAL
SERVUS_BSTR_32       51     D   string/bytearray            VAL
SERVUS_S_BSTR_00     52     D   short string/bytearray      VAL
SERVUS_S_BSTR_31     83     D   short string/bytearray      VAL
SERVUS_ARR_8         84     E   object array                CVAL
SERVUS_ARR_16        85     E   object array                CVAL
SERVUS_ARR_32        86     E   object array                CVAL
SERVUS_S_ARR_00      87     E   short array                 CVAL
SERVUS_S_ARR_15     102     E   short array                 CVAL
SERVUS_MAP_8        103     F   map/obj                     CVAL
SERVUS_MAP_16       104     F   map/obj                     CVAL
SERVUS_MAP_32       105     F   map/obj                     CVAL
SERVUS_S_MAP_00     106     F   short map                   CVAL
SERVUS_S_MAP_15     121     F   short map                   CVAL
SERVUS_TAG1_8       122     G   user type 1                 VAL
SERVUS_TAG1_16      123     G   user type 1                 VAL
SERVUS_TAG1_32      124     G   user type 1                 VAL
SERVUS_S_TAG1_00    125     G   short user type 1           VAL
SERVUS_S_TAG1_07    132     G   short user type 1           VAL
SERVUS_TAG2_8       133     H   user type 2                 VAL
SERVUS_TAG2_16      134     H   user type 2                 VAL
SERVUS_TAG2_32      135     H   user type 2                 VAL
SERVUS_S_TAG2_00    136     H   short user type 2           VAL
SERVUS_S_TAG2_07    143     H   short user type 2           VAL
SERVUS_SWITCH       144         switch                      CMD
SERVUS_HEADER       145         optional header             CMD
SERVUS_STATE_8      146         stateful 8                  CMD
SERVUS_STATE_16     147         stateful 16                 CMD
SERVUS_STATE_32     148         stateful 32                 CMD
SERVUS_STATE_64     149         stateful 64                 CMD
SERVUS_IMM_FIRST    150         immediate (-5)              VAL
SERVUS_IMM_LAST     255         immediate (100)             VAL

// other implicit constants
SERVUS_IMM_LEN      105
SERVUS_IMM_OFFSET   155
SERVUS_S_REF_LEN     32
SERVUS_S_BSTR_LEN    32
SERVUS_S_MAP_LEN     16
SERVUS_S_ARR_LEN     16
SERVUS_S_TAG1_LEN     8
SERVUS_S_TAG2_LEN     8

// All reserved values
SERVUS_RESERVED                 always
SERVUS_S_REF_00                 as first byte of the packet

```

Stateful:
- for communication
- for multipart serialization (one artifact references others)
- TBD


### Todos (unsorted)

* [ ] Document switch command
* [ ] Document semantics
* [ ] Finish the header definition
* [ ] Define `strict` mode
* [ ] Define `stateful` mode
* [ ] Think about schemas / ideas:
  * [ ] 'lite' schemas with follow C-Headers
  * [ ] User LuaJIT as core part: schema-def-and-code-generator-from-schema
* [ ] Build C sample
* [ ] Build C# sample
* [ ] Build JS/TS sample?
* [ ] Allow switch semantics for byte arrays?