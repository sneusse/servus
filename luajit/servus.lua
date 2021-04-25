local ffi = require("ffi")

local SERVUS_NULL = 0
local SERVUS_TRUE = 1
local SERVUS_FALSE = 2
local SERVUS_RESERVED = 3
local SERVUS_INT_8 = 4
local SERVUS_INT_16 = 5
local SERVUS_INT_32 = 6
local SERVUS_INT_64 = 7
local SERVUS_UINT_8 = 8
local SERVUS_UINT_16 = 9
local SERVUS_UINT_32 = 10
local SERVUS_UINT_64 = 11
local SERVUS_FLOAT_32 = 12
local SERVUS_FLOAT_64 = 13
local SERVUS_REF_8 = 14
local SERVUS_REF_16 = 15
local SERVUS_REF_32 = 16
local SERVUS_S_REF_00 = 17
local SERVUS_S_REF_31 = 48
local SERVUS_BSTR_8 = 49
local SERVUS_BSTR_16 = 50
local SERVUS_BSTR_32 = 51
local SERVUS_S_BSTR_00 = 52
local SERVUS_S_BSTR_31 = 83
local SERVUS_ARR_8 = 84
local SERVUS_ARR_16 = 85
local SERVUS_ARR_32 = 86
local SERVUS_S_ARR_00 = 87
local SERVUS_S_ARR_15 = 102
local SERVUS_MAP_8 = 103
local SERVUS_MAP_16 = 104
local SERVUS_MAP_32 = 105
local SERVUS_S_MAP_00 = 106
local SERVUS_S_MAP_15 = 121
local SERVUS_TAG1_8 = 122
local SERVUS_TAG1_16 = 123
local SERVUS_TAG1_32 = 124
local SERVUS_S_TAG1_00 = 125
local SERVUS_S_TAG1_07 = 132
local SERVUS_TAG2_8 = 133
local SERVUS_TAG2_16 = 134
local SERVUS_TAG2_32 = 135
local SERVUS_S_TAG2_00 = 136
local SERVUS_S_TAG2_07 = 143
local SERVUS_SWITCH = 144
local SERVUS_HEADER = 145
local SERVUS_STATE_8 = 146
local SERVUS_STATE_16 = 147
local SERVUS_STATE_32 = 148
local SERVUS_STATE_64 = 149
local SERVUS_IMM_FIRST = 150
local SERVUS_IMM_LAST = 255

local SERVUS_IMM_OFFSET = 155
local SERVUS_S_REF_LEN = 32
local SERVUS_S_BSTR_LEN = 32
local SERVUS_S_MAP_LEN = 16
local SERVUS_S_ARR_LEN = 16

ffi.cdef [[
    void* realloc (void* ptr, size_t size);

    typedef struct __attribute__((packed))
    {
        union {
            uint8_t cmd;
            uint8_t raw[0];
        };
        union
        {
            uint8_t data[0];
            int8_t s8;
            int16_t s16;
            int32_t s32;
            int64_t s64;
            uint8_t u8;
            uint16_t u16;
            uint32_t u32;
            uint64_t u64;
            float f32;
            double f64;
        };
    } servus_pack_helper;
]]

-- helpers
local _pack_ptr = ffi.typeof("servus_pack_helper*")
local _byte_ptr = ffi.typeof("uint8_t*")

-- the default method to allocate memory is realloc
local _default_allocator = function(buf, new, old)
    if new == 0 then
        ffi.C.realloc(buf, 0)
        return nil, 0
    end

    local twice = old * 2
    if new > old and new < twice then
        new = twice
    end

    -- allocator must return a byte buffer ?
    return ffi.cast(_byte_ptr, ffi.C.realloc(buf, new)), new
end


-- command constants
local SWITCH = {}

-- complex decoders follow inside the instance
local function read_coded_number(ptr, cmd, blockstart)
    local n = cmd - blockstart

    if n == 0 then
        return ptr.u8, 2
    elseif n == 1 then
        return ptr.u16, 3
    elseif n == 2 then
        return ptr.u32, 5
    end

    return n - 3, 1
end

    

-- create encoder/decoder
local function create(params)
    params = params or {}
    -- do not concat the resulting reftable and the packpart
    -- this saves a new allocation and does not matter if you can
    -- write the serial data in two parts to your file/socket.
    local concat = (params.concat ~= nil and params.concat) or true

    -- global switch to prefer speed > size, you still can fiddle with the individual
    -- parameters below
    local prefer_speed = (params.prefer_speed ~= nil and params.prefer_speed) or false

    -- disable cached writing and self references (2x speed in some cases)
    local no_cache = (params.no_cache ~= nil and params.no_cache) or prefer_speed

    -- force all numbers to be serialized as double
    local all_numbers_double = (params.all_numbers_double ~= nil and params.all_numbers_double) or prefer_speed

    -- serialization will be faster, but uses more memory
    --TODO: implement big maps again
    local use_big_maps = (params.use_big_maps ~= nil and params.use_big_maps) or prefer_speed

    -- A handler is a table to handle custom reads/writes
    -- see the default handler below for an example
    -- there can only be one handler. If you need extra functionality,
    -- you should combine them to a single one before attaching.
    local user_handler = params.user_handler

    -- the allocator to use. Look at the default one to see how the interface
    -- should look. 
    local allocator = params.allocator or _default_allocator
    local bufsz = params.bufsz and params.bufsz > 0 and params.bufsz or 4096

    -- =========== END OF PARAMS ============= --

    -- experimental switches
    local use_alternate_read_value = false

    -- cache the decoders
    local user_handler1 = user_handler and user_handler.tag1
    local user_handler2 = user_handler and user_handler.tag2


    -- cache stuff
    local cache_unresolved = {}
    local cache = {}
    local nextref = 0
    local reftab = {}

    -- forward declaration
    local write_value
    local api
    local floor = math.floor

    -- write/read buffer info
    local buflen = 0
    local write_buffer = nil
    local read_buffer = nil
    local pos = 0
    local capacity = 0

    -- create a metatable to prevent memory leaks
    local s_meta = {}
    s_meta.__gc = function ()
        if write_buffer then
            allocator(write_buffer, 0)
            write_buffer = nil
        end
    end

    -- create the instance and attach the gc handler
    local s = {}
    setmetatable(s, s_meta)

    local function add_to_cache(obj, loc)
        loc = loc or pos
        local ref = cache_unresolved[loc]
        -- check if the current object is present in the reftab
        if ref ~= nil then
            -- it is and it is not yet cached
            cache[ref] = obj
            -- remove it from the marker table
            cache_unresolved[loc] = nil
        end
    end

    -- simple type decoders
    local simple = {}

    for i = 0, 255 do
        simple[i] = function()
            error("Not implemented: " .. i)
        end
    end

    local read_value

    simple[SERVUS_NULL] = function()
        pos = pos + 1
        return nil
    end
    simple[SERVUS_TRUE] = function()
        pos = pos + 1
        return true
    end
    simple[SERVUS_FALSE] = function()
        pos = pos + 1
        return false
    end
    simple[SERVUS_RESERVED] = function()
        error("Reserved")
    end
    simple[SERVUS_INT_8] = function(ptr)
        pos = pos + 2
        return tonumber(ptr.s8)
    end
    simple[SERVUS_INT_16] = function(ptr)
        pos = pos + 3
        return tonumber(ptr.s16)
    end
    simple[SERVUS_INT_32] = function(ptr)
        pos = pos + 5
        return tonumber(ptr.s32)
    end
    simple[SERVUS_INT_64] = function(ptr)
        pos = pos + 9
        return ffi.new("int64_t", ptr.s64)
    end
    simple[SERVUS_UINT_8] = function(ptr)
        pos = pos + 2
        return tonumber(ptr.u8)
    end
    simple[SERVUS_UINT_16] = function(ptr)
        pos = pos + 3
        return tonumber(ptr.u16)
    end
    simple[SERVUS_UINT_32] = function(ptr)
        pos = pos + 5
        return tonumber(ptr.u32)
    end
    simple[SERVUS_UINT_64] = function(ptr)
        pos = pos + 9
        return ffi.new("uint64_t", ptr.u64)
    end
    simple[SERVUS_FLOAT_32] = function(ptr)
        pos = pos + 5
        return tonumber(ptr.f32)
    end
    simple[SERVUS_FLOAT_64] = function(ptr)
        pos = pos + 9
        return tonumber(ptr.f64)
    end
    simple[SERVUS_SWITCH] = function()
        pos = pos + 1
        return SWITCH
    end

    local function read_ref(ptr, cmd)
        -- if cache == nil then
        --     error("Invalid format: no refs present")
        -- end
        local ref, ofs = read_coded_number(ptr, cmd, SERVUS_REF_8)
        pos = pos + ofs
        return cache[ref], ofs
    end

    for i = SERVUS_REF_8, SERVUS_S_REF_31 do
        simple[i] = read_ref
    end

    local function read_bstr(ptr, cmd)
        local len, ofs = read_coded_number(ptr, cmd, SERVUS_BSTR_8)
        local b = ptr.raw + ofs
        local val = ffi.string(b, len)
        add_to_cache(val)
        pos = pos + ofs + len
        return val
    end

    for i = SERVUS_BSTR_8, SERVUS_S_BSTR_31 do
        simple[i] = read_bstr
    end

    local function read_arr(ptr, cmd)
        local len, ofs = read_coded_number(ptr, cmd, SERVUS_ARR_8)
        local val = {}
        add_to_cache(val)
        pos = pos + ofs
        for i = 1, len do
            val[i] = read_value()
        end
        return val
    end

    for i = SERVUS_ARR_8, SERVUS_S_ARR_15 do
        simple[i] = read_arr
    end

    local function read_map(ptr, cmd)
        local len, ofs = read_coded_number(ptr, cmd, SERVUS_MAP_8)
        local val = {}
        add_to_cache(val)
        pos = pos + ofs
        for i = 1, len do
            local k = read_value()
            if k == SWITCH then
                for j = 1, len - i + 1 do
                    val[j] = read_value()
                end
                break
            end
            val[k] = read_value()
        end
        return val
    end

    for i = SERVUS_MAP_8, SERVUS_S_MAP_15 do
        simple[i] = read_map
    end

    local function read_tag1(ptr, cmd)
        local id, ofs = read_coded_number(ptr, cmd, SERVUS_TAG1_8)
        local p = pos
        pos = pos + ofs
        return user_handler1(id, read_value, add_to_cache, p)
    end

    for i = SERVUS_TAG1_8, SERVUS_S_TAG1_07 do
        simple[i] = read_tag1
    end

    local function read_tag2(ptr, cmd)
        local id, ofs = read_coded_number(ptr, cmd, SERVUS_TAG2_8)
        local p = pos
        pos = pos + ofs
        return user_handler2(id, read_value, add_to_cache, p)
    end

    for i = SERVUS_TAG2_8, SERVUS_S_TAG2_07 do
        simple[i] = read_tag2
    end

    local function read_imm(ptr, cmd)
        pos = pos + 1
        return cmd - SERVUS_IMM_OFFSET
    end

    for i = SERVUS_IMM_FIRST, SERVUS_IMM_LAST do
        simple[i] = read_imm
    end

    if use_alternate_read_value then
        read_value = function()
            -- assert(pos < buflen, "malformed packet")
            local ptr = ffi.cast(_pack_ptr, read_buffer + pos)
            local cmd = ptr.cmd
            return simple[cmd](ptr, cmd)
        end
    else
        read_value = function()
            -- assert(pos < buflen, "malformed packet")
            local ptr = ffi.cast(_pack_ptr, read_buffer + pos)
            local cmd = ptr.cmd
            if cmd >= SERVUS_IMM_FIRST then
                pos = pos + 1
                return cmd - SERVUS_IMM_OFFSET
            elseif cmd <= SERVUS_FLOAT_64 then
                return simple[cmd](ptr)
            elseif cmd <= SERVUS_S_REF_31 then
                if cache == nil then
                    error("Invalid format: no refs present")
                end
                local ref, ofs = read_coded_number(ptr, cmd, SERVUS_REF_8)
                pos = pos + ofs
                return cache[ref]
            elseif cmd <= SERVUS_S_BSTR_31 then
                local len, ofs = read_coded_number(ptr, cmd, SERVUS_BSTR_8)
                local b = ptr.raw + ofs
                local val = ffi.string(b, len)
                add_to_cache(val)
                pos = pos + ofs + len
                return val
            elseif cmd <= SERVUS_S_ARR_15 then
                local len, ofs = read_coded_number(ptr, cmd, SERVUS_ARR_8)
                local val = {}
                add_to_cache(val)
                pos = pos + ofs
                for i = 1, len do
                    val[i] = read_value()
                end
                return val
            elseif cmd <= SERVUS_S_MAP_15 then
                local len, ofs = read_coded_number(ptr, cmd, SERVUS_MAP_8)
                local val = {}
                add_to_cache(val)
                pos = pos + ofs
                for i = 1, len do
                    local k = read_value()
                    if k == SWITCH then
                        for j = 1, len - i + 1 do
                            val[j] = read_value()
                        end
                        break
                    end
                    val[k] = read_value()
                end
                return val
            elseif cmd <= SERVUS_S_TAG1_07 then
                local id, ofs = read_coded_number(ptr, cmd, SERVUS_TAG1_8)
                local p = pos
                pos = pos + ofs
                return user_handler1(id, read_value, add_to_cache, p)
            elseif cmd <= SERVUS_S_TAG2_07 then
                local id, ofs = read_coded_number(ptr, cmd, SERVUS_TAG2_8)
                local p = pos
                pos = pos + ofs
                return user_handler2(id, read_value, add_to_cache, p)
            elseif cmd == SERVUS_SWITCH then
                pos = pos + 1
                return SWITCH
            else
                return error("Not implemented")
            end
        end
    end

    s.load = function(buf, refbuf)
        -- reset the read_buffer
        buflen = #buf
        cache = {}
        cache_unresolved = {}
        pos = 0

        read_buffer = ffi.cast(_byte_ptr, refbuf or buf)
        local ptr = ffi.cast(_pack_ptr, read_buffer)
        local first = ptr.cmd
        if first >= SERVUS_REF_8 and first <= SERVUS_S_REF_31 then
            local len, ofs = read_coded_number(ptr, first, SERVUS_REF_8)
            pos = pos + ofs

            local refs = {}
            for i = 0, len - 1 do
                local val = read_value()
                refs[i] = val
                cache_unresolved[val] = i
            end

            cache = refs
            if refbuf then
                -- separate read_buffer
                read_buffer = ffi.cast(_byte_ptr, buf)
            else
                -- move the read_buffer to the packpart
                read_buffer = read_buffer + pos
            end
            pos = 0
        end

        local val = read_value()

        -- reset the read_buffer
        read_buffer = nil

        return val
    end

    --[[============================================================================= WRITER ]]

    local function _ensure_buffer_capacity(extra)
        local newsize = pos + extra
        if newsize > capacity then
            local mem, capa = allocator(write_buffer, newsize, capacity)
            write_buffer = mem
            capacity = capa
        end

        return ffi.cast(_pack_ptr, write_buffer + pos)
    end

    local function write_encoded(ptr, num, blockstart, shortlen)
        if num < shortlen then
            ptr.cmd = blockstart + 3 + num
            pos = pos + 1
            return 1
        elseif num < 2 ^ 8 then
            ptr.cmd = blockstart
            ptr.u8 = num
            pos = pos + 2
            return 2
        elseif num < 2 ^ 16 then
            ptr.cmd = blockstart + 1
            ptr.u16 = num
            pos = pos + 3
            return 3
        elseif num < 2 ^ 32 then
            ptr.cmd = blockstart + 2
            ptr.u32 = num
            pos = pos + 5
            return 5
        else
            error("number cannot be encoded as command")
        end
    end

    local function write_command(cmd)
        local ptr = _ensure_buffer_capacity(1)
        ptr.cmd = cmd
        pos = pos + 1
    end

    local function write_string(str, len)
        len = len or #str
        local ptr = _ensure_buffer_capacity(len + 5)
        local ps = ffi.cast(_byte_ptr, str)
        local ofs = write_encoded(ptr, len, SERVUS_BSTR_8, SERVUS_S_BSTR_LEN)
        ffi.copy(ptr.raw + ofs, ps, len)
        pos = pos + len
    end

    local write_number
    if all_numbers_double then
        write_number = function(num)
            local ptr = _ensure_buffer_capacity(9)
            ptr.cmd = SERVUS_FLOAT_64
            ptr.f64 = num
            pos = pos + 9
        end
    else
        write_number = function(num)
            local ptr = _ensure_buffer_capacity(9)
            if floor(num) == num and num >= -2147483648 and num <= 2147483647 then -- TODO: unsigned?
                if num >= -5 and num <= 100 then
                    ptr.cmd = num + SERVUS_IMM_OFFSET
                    pos = pos + 1
                elseif num >= -128 and num <= 127 then
                    ptr.cmd = SERVUS_INT_8
                    ptr.s8 = num
                    pos = pos + 2
                elseif num >= -32768 and num <= 32767 then
                    ptr.cmd = SERVUS_INT_16
                    ptr.s16 = num
                    pos = pos + 3
                else
                    ptr.cmd = SERVUS_INT_32
                    ptr.s32 = num
                    pos = pos + 5
                end
            else
                ptr.cmd = SERVUS_FLOAT_64
                ptr.f64 = num
                pos = pos + 9
            end
        end
    end

    local function write_table(tab)
        local array_len = #tab
        local first_key, first_val = next(tab, array_len > 0 and array_len or nil)
        local has_keys = first_key ~= nil

        local ptr = _ensure_buffer_capacity(8)

        -- empty table
        if array_len == 0 and not has_keys then
            ptr.cmd = SERVUS_S_MAP_00
            pos = pos + 1
            return
        end

        -- map part
        if has_keys then
            -- we could also always use the 4 byte map type to prevent
            -- iterating twice. A tradeoff between memory and performance.
            local map_len = 0
            local k = first_key
            while k ~= nil do
                map_len = map_len + 1
                k = next(tab, k)
            end

            local total_len = array_len + map_len

            -- encode the command
            write_encoded(ptr, total_len, SERVUS_MAP_8, SERVUS_S_MAP_LEN)

            local v = first_val
            k = first_key
            while k ~= nil do
                write_value(k)
                write_value(v)
                k,v = next(tab, k)
            end
        else
            write_encoded(ptr, array_len, SERVUS_ARR_8, SERVUS_S_ARR_LEN)
        end

        -- array part
        if array_len > 0 then
            if has_keys then
                write_command(SERVUS_SWITCH)
            end
            for i = 1, array_len do
                write_value(tab[i])
            end
        end
    end

    local function write_bool(val)
        local ptr =_ensure_buffer_capacity(1)
        ptr.cmd = val and SERVUS_TRUE or SERVUS_FALSE
        pos = pos + 1
        return
    end

    local function write_nil(_)
        local ptr =_ensure_buffer_capacity(1)
        ptr.cmd = SERVUS_NULL
        pos = pos + 1
        return
    end

    local write_not_supported = function (val)
        error("Cannot serialize " .. type(val) .. ". Maybe this can be enabled?")
    end

    local do_not_cache = function (next, val)
        return next(val)
    end

    local do_cache = function (next, val)
        -- do we already have a cached version?
        local ref = cache[val]
        if ref ~= nil then
            -- ref is not used yet, mark it used
            if ref < 0 then
                -- save the original value to the reftab
                reftab[nextref] = -ref - 1

                -- emit the index to use
                ref = nextref
                -- and update the cache
                cache[val] = ref

                -- move to the next free slot
                nextref = nextref + 1
            end
            local ptr =_ensure_buffer_capacity(5)
            return write_encoded(ptr, ref, SERVUS_REF_8, SERVUS_S_REF_LEN)
        end
        -- cache the value: we save the position where
        -- the VALUE would start. The deserializer will
        -- have to track the positions to reconstruct
        -- these eventually.

        -- neagtive numbers indicate that the object is not yet referenced!
        -- we use the offset to make signed checks easier (prevent neagtive 0)
        cache[val] = -(pos + 1)
        return next(val)
    end

    local cache_funcs = {
        ["number"] = do_not_cache,
        ["boolean"] = do_not_cache,
        ["nil"] = do_not_cache,
        ["string"] = do_cache,
        ["table"] = do_cache,
        ["userdata"] = do_cache,
        ["cdata"] = do_cache,
        ["function"] = do_cache,
        ["thread"] = do_cache
    }

    local writers = {
        ["number"] = write_number,
        ["boolean"] = write_bool,
        ["nil"] = write_nil,
        ["string"] = write_string,
        ["table"] = write_table,
        ["userdata"] = write_not_supported,
        ["cdata"] = write_not_supported,
        ["function"] = write_not_supported,
        ["thread"] = write_not_supported
    }

    -- move all up to be execute before the cache logic (faster)
    if no_cache then
        for key, _ in pairs(cache_funcs) do
            cache_funcs[key] = do_not_cache
        end
    end

    -- add the user handlers
    if user_handler and user_handler["string"] then
        writers["string"] = user_handler["string"]
    end
    if user_handler and  user_handler["table"] then
        writers["table"] = user_handler["table"]
    end
    if user_handler and  user_handler["cdata"] then
        writers["cdata"] = user_handler["cdata"]
    end
    if user_handler and  user_handler["func"] then
        writers["function"] = user_handler["func"]
    end


    write_value = function(val)
        local tp = type(val)

        local cf = cache_funcs[tp]
        local wf = writers[tp]

        return cf(wf, val)
    end

    -- setup user API
    api = {
        -- use this whenever possible
        write_value = write_value,
        write_command = write_command,
        write_nil = write_nil,
        write_bool = write_bool,
        write_number = write_number,
        write_table = write_table,
        write_string = write_string,
        write_tag1 = function(num)
            local ptr = _ensure_buffer_capacity(5)
            write_encoded(ptr, num, SERVUS_TAG1_8, SERVUS_S_TAG1_07)
        end,
        write_tag2 = function(num)
            local ptr = _ensure_buffer_capacity(5)
            write_encoded(ptr, num, SERVUS_TAG2_8, SERVUS_S_TAG2_07)
        end
    }

    if user_handler then
        user_handler.api = api
    end

    -- the serializer
    s.dump = function(obj)
        pos = 0
        nextref = 0
        cache = {}
        reftab = {}

        _ensure_buffer_capacity(bufsz)

        -- begin serializetion
        write_value(obj)

        -- dump the pack part, so we can reuse the write_buffer
        local pack_part = ffi.string(write_buffer, pos)

        -- now write the reftab (same semantics as arrays)
        -- but only when there is content
        if nextref > 0 then
            -- reset the write_buffer
            pos = 0

            local ptr = _ensure_buffer_capacity(4)

            write_encoded(ptr, nextref, SERVUS_REF_8, SERVUS_S_REF_LEN)

            -- references start at 0
            for i = 0, nextref - 1 do
                -- write the position of the value
                write_number(reftab[i])
            end

            local refstr = ffi.string(write_buffer, pos)

            if concat then
                return refstr .. pack_part
            end
            return pack_part, refstr
        end

        return pack_part
    end

    --- free the memory
    s.clear = function()
        write_buffer, capacity = allocator(write_buffer, 0)
    end

    return s, s.dump, s.load
end

-- cdata and function serialization

local function upvals(func)
    local env = debug.getfenv(func)
    local uval = {}
    local num = 1

    local discard = {}
    for key, value in pairs(package.loaded) do
        discard[key] = true
        discard[value] = true
    end


    while true do
        local name, val = debug.getupvalue(func, num)
        if name == nil then
            break
        end
        if env[name] then
            error("Only local upvalues should be used.")
        end
        if discard[name] or discard[val] then
            error("Serializing packages is maybe not a good idea.")
        end
        uval[num] = val
        num = num + 1
    end
    return uval
end

local function create_handler(typemap, allow_cdata, allow_func)
    local h = {}
    local typecache = {}

    typemap = typemap or {}
    allow_cdata = allow_cdata ~= nil and allow_cdata or true
    allow_func = allow_func ~= nil and allow_func or true

    h.typemap = typemap

    local function cache_type(cdata)
        local ctype = ffi.typeof(cdata)
        local tidx = tonumber(ctype)
        local cached = typecache[tidx]
        if cached == nil then
            local typename = typemap[tidx]
            if not typename then
                local typestr = tostring(ctype):sub(7, -2)
                local sid = typestr:match("struct (%d+)")
                if sid then
                    typename = typemap[tonumber(sid)]
                    if typename then
                        typename = typestr:gsub("struct %d+", typename)
                    end
                end

                -- fallback: try to use the type from name
                typename = typename or typestr
            end
            local len = ffi.sizeof(ctype)
            local ptrtype = ffi.typeof("$*", ctype)
            local arraytype = ffi.typeof("$[1]", ctype)
            local write, read
            if len > 8 * 1024 and (typename:find("%[") or typename:find("%*") or typename:find("&"))  then
                -- don't use the stack to copy this.
                write = function(v)
                    h.api.write_tag2(0)
                    h.api.write_value(typename)
                    h.api.write_string(ffi.cast(_byte_ptr, v), len)
                end
                read = function(read_value)
                    local data = read_value()
                    local tmp = ffi.cast(ptrtype, data)
                    local new = ffi.new(ctype)
                    ffi.copy(new, tmp, len)
                    return new
                end
            else
                local slot = ffi.new(arraytype)
                write = function(v)
                    slot[0] = v
                    h.api.write_tag2(0)
                    h.api.write_value(typename)
                    h.api.write_string(slot, len)
                end
                read = function(read_value)
                    local data = read_value()
                    local tmp = ffi.cast(ptrtype, data)
                    return ffi.new(ctype, tmp[0])
                end
            end

            cached = {read = read, write = write}
            typecache[tidx] = cached
        end
        return cached
    end

    if allow_func then
        h.func = function(val)
            h.api.write_tag2(10000)
            local d = string.dump(val)
            local u = upvals(val)
            h.api.write_string(d)
            h.api.write_value(u)
        end
    end

    if allow_cdata then
        h.cdata = function(val)
            cache_type(val).write(val)
        end
    end


    h.tag1 = function(id, read_value, add_to_cache, pos)
        return read_value()
    end
    h.tag2 = function(id, read_value, add_to_cache, pos)
        if id == 0 and allow_cdata then
            local type = read_value()
            local cached = cache_type(type)
            local v = cached.read(read_value)
            return v
        end
        if id == 10000 and allow_func then
            local d = read_value()
            local f = load(d)
            add_to_cache(f, pos)
            local upvalues = read_value()
            for key, value in ipairs(upvalues) do
                debug.setupvalue(f,key,value)
            end
            return f
        end
        return {read_value(), read_value()}
    end
    return h
end

if _G.SERVUS_RUN_TESTS then ---------------------------------------- TESTS

    -- the default instance
    local _inst = create()
    local _dump = _inst.dump
    local _load = _inst.load

    -- require penlight for deepcompare
    local deepcompare = require("pl.tablex").deepcompare
    local t1, t2, t3, r1, r2, r3, r4

    local roundtrip = function(obj, f)
        local d = _dump(obj)
        local rt = _load(d)
        if f == false then
            return rt, d
        end
        if f and type(f) == "function" then
            rt = f(rt)
            obj = f(obj)
        end
        assert(deepcompare(rt, obj))
        if f and type(f) == "number" then
            assert(#d == f)
        end
        return rt, d
    end
    
    local result = {
        number = 42,
        string = 'text',
        bool = true,
        nested = { }
    }

    local current = result
    for i = 1, 100 do
        current.nested = {
            number = i,
            string = 'text ' .. i,
            bool = true,
        }
        current = current.nested
    end
    roundtrip(result)

    local r, d
    roundtrip(0, 1)
    roundtrip(true, 1)
    roundtrip(false, 1)
    roundtrip(256)
    roundtrip(-5, 1)
    roundtrip(100, 1)
    roundtrip(-1, 1)
    roundtrip(0x123321, 5)
    roundtrip(0xFFFFFFFF)
    roundtrip(0xFFFFFFFFFFFFFFFF)
    roundtrip("Hello ♥", 10)
    roundtrip("😂 🥝 🦞	😂")
    roundtrip(nil, 1)
    roundtrip(0 / 0, tostring) -- NaN != NaN
    roundtrip(1 / 0, 9)
    roundtrip(-1 / 0, 9)
    assert(#roundtrip {1, 2, 3} == 3)
    roundtrip({-1, 0, 1, 25, 30, nil, "STUFF"})
    roundtrip({{{{{{{{{{{{-1, 0, 1, 25, 30, nil, "STUFF"}}}}}}}}}}}})
    roundtrip({{0, {{1, {{{2, {{3, {{{-1, 0, 1, 25, 30, nil, "STUFF"}}}}}}}}}}}})
    roundtrip({})
    roundtrip({string.rep("A", 1024 * 1024)})

    t1 = {}
    t2 = {}
    t1[t2] = 3
    r1 = roundtrip(t1, false)
    assert(#t1 == #r1)
    assert(type(next(t1)) == type(next(r1)))

    t2 = {8, 9}
    t1 = {1, 2, 3, a = 23, b = 33, "HELLO"}
    t1.x = t1
    t1.y = t2
    t2.x = t1
    t2.y = t2
    r1 = roundtrip(t1) -- this looks weird
    r1 = roundtrip(t1) -- but next() order
    r1 = roundtrip(t1) -- is not predictble.
    r1 = roundtrip(t1) -- And there was a bug
    r1 = roundtrip(t1) -- which only occured
    r1 = roundtrip(t1) -- 'sometimes' depending
    r1 = roundtrip(t1) -- what next() returned
    r1 = roundtrip(t1) -- first.
    r1 = roundtrip(t1)
    r1 = roundtrip(t1)

    t1 = {}
    t2 = {}
    for i = 1, 10 do
        for j = 1, 10 do
            t1[i * j] = t2
            t2[i * j] = t1
            t1[i] = 234
            t2.test = t1
            t1.test = {t2, t1}
        end
    end

    roundtrip(t1)


    -- enable user types cdata and function
    local types = {}
    _inst,_dump,_load = create {
        user_handler = create_handler(types, true, true)
    }
    roundtrip(0xFFFFFFFFFFFFFFFFULL)

    ffi.cdef[[
        typedef struct { float x; float y; } vec2;
    ]]

    types[tonumber(ffi.typeof("vec2"))] = "vec2"
    types[tonumber(ffi.typeof("vec2[1024]"))] = "vec2[1024]"

    t1 = ffi.new("vec2")
    t1.x = 123
    t1.y = 321
    t2 = _dump(t1)
    r1 = _load(_dump(t1))
    assert(r1.x == t1.x and r1.y == t1.y)

    t1 = ffi.new("vec2[1024]")
    for i = 0, 1023 do
        t1[i].x = i
        t1[i].y = 2*i
    end

    r1 = _load(_dump(t1))
    assert(ffi.sizeof(r1) == ffi.sizeof(t1))
    for i = 0, 1023 do
        assert(r1[i].x == t1[i].x and r1[i].y == t1[i].y)
    end

    t1 = function()
        return "easy"
    end

    r1 = _load(_dump(t1))
    assert(r1() == "easy")

    local upval = {1,2,3,4,5,"FOO"}

    t1 = function(param)
        return upval[6] .. "BAR", upval, param + upval[1]
    end

    r1 = _load(_dump(t1))

    assert(deepcompare({t1(5)}, {r1(5)}))


    t1 = function(param)
        return upval[6] .. "BAR", upval, param + upval[1]
    end
    t2 = {t1(5)}
    t3 = _dump(t1)
    t1 = nil
    upval = nil
    collectgarbage()
    r1 = _load(t3)
    r2 = {r1(5)}

    assert(deepcompare(t2, r2))

    -- test recursive interdepended functions
    -- this requres correct cache handling
    t2 = function(p2)
        return p2 > 0 and t1(p2-1) or 0
    end

    t1 = function(p1)
        return p1 > 0 and t2(p1-1) or 0
    end

    r1 = _dump(t1)
    r2 = _load(r1)
    assert(r2(20) == t2(20))

    _dump({compact = true, schema = 0})

    _inst.clear()
    collectgarbage("collect")

    io.stderr:write("ALL TESTS DONE!\n")
end


return {create = create, create_handler = create_handler}
