-- Tiny test harness shared by the unit tests: ok / eq, and a summary that sets the exit code. Writes with io.write,
-- so a test may replace the global print (main_test captures the mod's log lines through it).
local H = {}
function H.new(name)
    local T = { name = name, passed = 0, failed = 0 }
    function T.ok(cond, label, detail)
        if cond then T.passed = T.passed + 1
        else
            T.failed = T.failed + 1
            io.write("FAIL " .. label .. (detail and (" -- " .. tostring(detail)) or "") .. "\n")
        end
    end
    function T.eq(got, want, label) T.ok(got == want, label, "got " .. tostring(got) .. ", want " .. tostring(want)) end
    function T.done()
        io.write(string.format("%s: %d passed, %d failed\n", T.name, T.passed, T.failed))
        os.exit(T.failed == 0 and 0 or 1)
    end
    return T
end
return H
