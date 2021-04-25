local servus = require("servus")
local ser = servus.create()

-- ? 1. simple example =================================================================

local my_data = {1, 2, 3, 4, key = "value"}

local my_data_serialized = ser.dump(my_data)

-- see the string
-- print(my_data_serialized, #my_data_serialized)

-- parse it back
local my_data_back = ser.load(my_data_serialized)
assert(my_data_back.key == my_data.key)
-- print(my_data_back, my_data_back.key)

-- ? 2. complex example ================================================================

local ffi = require("ffi")

-- for the cdata we need a typemap as the name cannot
-- be parsed back in every case. If you only need simple
-- types (int, float, double, ...) you can pass a empty table

-- helpers to cache the types
-- the map itself needs to look exactly like this!
local type_names = {}
local function add_to_typemap(typename)
    type_names[tonumber(ffi.typeof(typename))] = typename
end

-- define your user type
ffi.cdef [[
    typedef struct { float x; float y; } vec2;
]]

-- register the type
-- arrays of this type can now be used too!
add_to_typemap("vec2")

-- enable the extra serializer extension for cdata and functions
ser = servus.create {user_handler = servus.create_handler(type_names)}

local UpvaluesAreSerializedToo = {"YEAH!"}

-- be careful, pointers will get serialized, not the memory they point to.
-- this is by design as this helps with data exchange in multithreading apps.
local ptr = ffi.cast("void*", ffi.cast("intptr_t", 0xdeadbeef))

local my_complex_data = {
    func = function(self, n)
        return string.rep(UpvaluesAreSerializedToo[1], n) .. self.other
    end,
    other = "data",
    myvec = ffi.new("vec2"),
    pointer = ptr,
    always_works = ffi.new("int[100]"), -- <-- copy up to 8*1024 b will use the stack
    array_of_vecs = ffi.new("vec2[10000]"), -- <- look ma, I don't have to teach them this type!
    array_of_vecs2d = ffi.new("vec2[1000][1000]"), -- <- careful with big structs
}

-- all references will be references after deserialization again.
local unique = {}
for i = 1, 10 do
    my_complex_data[i] = unique
end

-- assign some basic values
my_complex_data.myvec.x = 3
my_complex_data.myvec.y = 25
my_complex_data.array_of_vecs[0].x = 13.3
my_complex_data.array_of_vecs2d[321][123].x = 42

-- allowed by spec and the sample parser/decoder implements it properly
my_complex_data.selfref = my_complex_data

-- roundtrip
local my_complex_data_dump = ser.dump(my_complex_data)
local my_complex_data_back = ser.load(my_complex_data_dump)

-- selfref works
assert(my_complex_data_back == my_complex_data_back.selfref)

-- all other references too
for i = 1, 10 do
    assert(my_complex_data_back[i] == my_complex_data_back[1])
end

-- cdata works
assert(my_complex_data.myvec.x == my_complex_data_back.myvec.x)

-- array of types should work
assert(my_complex_data.array_of_vecs[0].x == my_complex_data_back.array_of_vecs[0].x)
assert(my_complex_data.array_of_vecs2d[321][123].x == my_complex_data_back.array_of_vecs2d[321][123].x)

-- pointers work
assert(my_complex_data.pointer == my_complex_data_back.pointer)

-- function call with local upvalue works.
assert(my_complex_data_back:func(2) == "YEAH!YEAH!data")

-- ! UPVALUES ARE COPIED! WHEN YOU CHANGE THE LOCAL VALUE, THE
-- ! SERIALIZED VERSION IS STILL THE OLD ONE AND DOES NOT CHANGE!
-- ! SO YOU CAN EVEN DELETE THE ORIGINAL!

UpvaluesAreSerializedToo[1] = nil
UpvaluesAreSerializedToo = nil
collectgarbage("collect")

-- reparse it again to show that references are not needed
-- if you need different behaviour you should extend the parser
assert(ser.load(my_complex_data_dump):func(3) == "YEAH!YEAH!YEAH!data")

-- ? 3. my use-case: threading =========================================================
-- I need to pass a function call with arguments to a seperate thread.

ffi.cdef [[
    void* realloc (void* ptr, size_t size);
]]

local other_stuff = 321

-- this memory can be accessed from both threads
-- there is no synchronization, so you'll have to roll your own
local done = ffi.cast("volatile bool*", ffi.C.realloc(nil, 8))
local function run_somewhere_else(p)
    -- do work.
    done[0] = true
    return p * other_stuff
end

-- this can be done in three lines now:
local serialized_call = ser.dump {args = {2}, fun = run_somewhere_else}

-- somewhere on another thread...
local remote_call = ser.load(serialized_call)
print(remote_call.fun(unpack(remote_call.args))) -- prints 642
print("done: ", done[0]) -- true
