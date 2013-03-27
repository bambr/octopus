require("fiber")
require("box")
require("netmsg")
require("index")
local ffi = require("ffi")
local bit = require("bit")

local pcall, error, print, ipairs, pairs, type = pcall, error, print, ipairs, pairs, type
local string, tonumber, tostring, table, netmsg, box, fiber, index = string, tonumber, tostring, table, netmsg, box, fiber, index

user_proc = user_proc or {}
local user_proc = user_proc

module(...)

-- simple definition via  box.defproc
user_proc.get_all_tuples = box.wrap(function (n)
	local result = {}
        local object_space = box.object_space[n]
        local function next_chunk(idx, start)
                local count, batch_size = 0, 3000
                for tuple in index.iter(idx, start) do
                        if (count == batch_size) then
                                -- return last tuple not putting it into result
                                -- outer iteration will use is as a restart point
                                return tuple
                        end
                        table.insert(result, tuple)
                        count = count + 1
                end
                return nil
        end

        -- iterate over all chunks
        for restart in next_chunk, object_space.index[1] do
                fiber.sleep(0.001)
        end

        local retcode = 0
        return retcode, result
end)

-- raw access to internals
user_proc.get_all_pkeys =
        function (out, n, batch_size)
                local object_space = box.space[n]

                if not object_space then
                        error(string.format("no such object_space: %s", n))
                end

                local key_count = 0
                if batch_size == nil or batch_size <= 42 then
                        batch_size = 42
                end

                local key_count_promise = netmsg.add_iov(out, nil) -- extract promise

                local function next_chunk(idx, start)
                        local count, keys = 0, {}

                        for tuple in index.iter(idx, start) do
                                if (count == batch_size) then
                                        return tuple, keys
                                end

                                table.insert(keys, string.tofield(tuple[0]))
                                count = count + 1
                        end
                        -- the loop is done, indicate that returning false and the residual
                        return false, keys
                end

                -- note, this iterator signals end of iteration by returning false, not nil
                -- this is done because otherwise the residual from last iteration is lost
                for restart, keys in next_chunk, object_space.index[1] do
                        if #keys > 0 then
                                key_count = key_count + #keys
                                local pack = table.concat(keys)
                                netmsg.add_iov(out, pack, #pack)
                        end
                        if restart == false then
                                break
                        end
                        fiber.sleep(0.001)
                end

                netmsg.fixup_promise(key_count_promise, string.tou32(key_count))

                local retcode = 0
                return retcode
        end

-- periodic processing
user_proc.drop_first_tuple = box.wrap(function ()
	local function drop_first_tuple()
                fiber.sleep(1)
                local object_space = box.object_space[0]
                local idx = object_space.index[0]
                while true do
                        print("lookin for a tuple")
                        for tuple in index.iter(idx) do
                                print("found, killin it")
                                box.delete(object_space, tuple[0])
                                break
                        end
                        print("sleepin")
                        fiber.sleep(5)
                end
        end

        fiber.create(drop_first_tuple)
        return 0
end)


user_proc.sum_u64 = box.wrap(function (n, pk)
        local object_space = box.object_space[n]
        local obj = object_space.index[0][pk]
        if not obj then
                return 0, {"not found"}
        end
        
        local t = box.ctuple(obj);
        local f, offt, len = {}, 0
        for i = 0,t[0].cardinality - 1 do 
                len, offt = box.decode_varint32(t[0].data, offt)
                if len == 8 then
                        table.insert(f, ffi.cast("uint64_t *", t[0].data + offt)[0])
                elseif len == 4 then
                        table.insert(f, ffi.cast("uint32_t *", t[0].data + offt)[0])
                else
                        table.insert(f, ffi.string(t[0].data + offt, len))
                end
                offt = offt + len
        end

        local sum = 0
        for k, v in ipairs(f) do
                local n = tonumber(v)
                if n ~= nil then
                        sum = sum + n
                end
        end

        return 0, {box.tuple(sum)}
end)
