local files  = require 'files'
local guide  = require 'parser.guide'
local vm     = require 'vm'
local lang   = require 'language'
local await  = require 'await'
local define = require 'proto.define'

---@param block parser.object
---@return boolean
local function hasReturn(block)
    if block.hasReturn or block.hasError then
        return true
    end
    if block.type == 'if' then
        local hasElse
        for _, subBlock in ipairs(block) do
            if not hasReturn(subBlock) then
                return false
            end
            if subBlock.type == 'elseblock' then
                hasElse = true
            end
        end
        return hasElse == true
    else
        if block.type == 'while' then
            if vm.testCondition(block.filter) then
                return true
            end
        end
        for _, action in ipairs(block) do
            if guide.isBlockType(action) then
                if hasReturn(action) then
                    return true
                end
            end
        end
    end
    return false
end

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceTypes(state.ast, {'main', 'function'}, function (source)
        await.delay()
        if not source.returns then
            return
        end
        for i, action in ipairs(source) do
            if  guide.isBlockType(action)
            and hasReturn(action) then
                if i < #source then
                    callback {
                        start   = source[i+1].start,
                        finish  = source[#source].finish,
                        tags    = { define.DiagnosticTag.Unnecessary },
                        message = lang.script('DIAG_UNREACHABLE_CODE'),
                    }
                end
                return
            end
        end
    end)
end
