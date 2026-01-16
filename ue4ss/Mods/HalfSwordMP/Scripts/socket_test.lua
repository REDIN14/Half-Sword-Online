-- Test script to check if UE4SS has socket support
-- Run this and check the log

print("=== Testing Socket Support ===")

-- Test 1: Try to require socket
local function testRequire(name)
    local success, result = pcall(function() 
        return require(name) 
    end)
    if success then
        print("[OK] require('" .. name .. "') works!")
        return result
    else
        print("[FAIL] require('" .. name .. "'): " .. tostring(result))
        return nil
    end
end

-- Try different socket module names
testRequire("socket")
testRequire("socket.core")
testRequire("luasocket")

-- Test 2: Check if io.popen works (could use for inter-process communication)
local function testPopen()
    local success, result = pcall(function()
        local handle = io.popen("echo test")
        if handle then
            local output = handle:read("*a")
            handle:close()
            return output
        end
    end)
    if success then
        print("[OK] io.popen works!")
    else
        print("[FAIL] io.popen: " .. tostring(result))
    end
end

testPopen()

-- Test 3: Check package.cpath (where DLLs are loaded from)
print("\npackage.cpath:")
print(package.cpath or "nil")

print("\npackage.path:")
print(package.path or "nil")

print("\n=== Socket Test Complete ===")
print("Check output above. If all FAIL, LuaSocket is not available.")
