local vm       = require 'vm'
local ws       = require 'workspace'
local markdown = require 'provider.markdown'
local config   = require 'config'
local lang     = require 'language'
local util     = require 'utility'
local guide    = require 'parser.guide'
local rpath    = require 'workspace.require-path'
local furi     = require 'file-uri'

local function collectRequire(mode, literal, uri)
    local result, searchers
    if     mode == 'require' then
        result, searchers = rpath.findUrisByRequirePath(uri, literal)
    elseif mode == 'dofile'
    or     mode == 'loadfile' then
        result = ws.findUrisByFilePath(literal)
    end
    if result and #result > 0 then
        local shows = {}
        for i, uri in ipairs(result) do
            local searcher = searchers and searchers[uri]
            local path = ws.getRelativePath(uri)
            if vm.isMetaFile(uri) then
                shows[i] = ('* [[meta]](%s)'):format(uri)
            elseif searcher then
                searcher = searcher:gsub('^[/\\]+', '')
                shows[i] = ('* [%s](%s) %s'):format(path, uri, lang.script('HOVER_USE_LUA_PATH', searcher))
            else
                shows[i] = ('* [%s](%s)'):format(path, uri)
            end
        end
        table.sort(shows)
        local md = markdown()
        md:add('md', table.concat(shows, '\n'))
        return md
    end
end

local function asStringInRequire(source, literal)
    local parent = source.parent
    if parent and parent.type == 'callargs' then
        local call = parent.parent
        local func = call.node
        local libName = vm.getLibraryName(func)
        if not libName then
            return
        end
        if libName == 'require'
        or libName == 'dofile'
        or libName == 'loadfile' then
            return collectRequire(libName, literal, guide.getUri(source))
        end
    end
end

local function asStringView(source, literal)
    -- 内部包含转义符？
    if not source[2] then
        return
    end
    local rawLen = source.finish - source.start - 2 * #source[2]
    if  config.get(guide.getUri(source), 'Lua.hover.viewString')
    and (source[2] == '"' or source[2] == "'")
    and rawLen > #literal then
        local view = literal
        local max = config.get(guide.getUri(source), 'Lua.hover.viewStringMax')
        if #view > max then
            view = view:sub(1, max) .. '...'
        end
        local md = markdown()
        md:add('txt', view)
        return md
    end
end

local function asString(source)
    local literal = guide.getLiteral(source)
    if type(literal) ~= 'string' then
        return nil
    end
    return asStringInRequire(source, literal)
        or asStringView(source, literal)
end

local function getBindComment(source)
    local lines = {}
    for _, docComment in ipairs(source.bindComments) do
        if docComment.comment.text:sub(1, 1) == '-' then
            lines[#lines+1] = docComment.comment.text:sub(2)
        else
            lines[#lines+1] = docComment.comment.text
        end
    end
    if not lines or #lines == 0 then
        return nil
    end
    return table.concat(lines, '\n')
end

---@param comment string
---@param suri uri
---@return string?
local function normalizeComment(comment, suri)
    if comment:sub(1, 1) == '-' then
        comment = comment:sub(2)
    end
    if comment:sub(1, 1) == '@' then
        return nil
    end
    comment = comment:gsub('(%[.-%]%()(.-)(%))', function (left, path, right)
        if path:match '^file:/' then
            return
        end
        local absPath = ws.getAbsolutePath(suri:gsub('/[^/]+$', ''), path)
        if not absPath then
            return
        end
        local uri     = furi.encode(absPath)
        return left .. uri .. right
    end)
    return comment
end

local function lookUpDocComments(source, docGroup)
    if source.type == 'setlocal'
    or source.type == 'getlocal' then
        source = source.node
    end
    if source.parent.type == 'funcargs' then
        return
    end
    local uri = guide.getUri(source)
    local lines = {}
    for _, doc in ipairs(docGroup) do
        if doc.type == 'doc.comment' then
            local comment = normalizeComment(doc.comment.text, uri)
            lines[#lines+1] = comment
        elseif doc.type == 'doc.type' then
            if doc.comment then
                lines[#lines+1] = doc.comment.text
            end
        elseif doc.type == 'doc.class' then
            for _, docComment in ipairs(doc.bindComments) do
                if docComment.comment.text:sub(1, 1) == '-' then
                    lines[#lines+1] = docComment.comment.text:sub(2)
                else
                    lines[#lines+1] = docComment.comment.text
                end
            end
        end
        ::CONTINUE::
    end
    if source.comment then
        lines[#lines+1] = source.comment.text
    end
    if not lines or #lines == 0 then
        return nil
    end
    return table.concat(lines, '\n')
end

local function tryDocClassComment(source)
    for _, def in ipairs(vm.getDefs(source)) do
        if def.type == 'doc.class'
        or def.type == 'doc.alias' then
            local comment = getBindComment(def)
            if comment then
                return comment
            end
        end
    end
end

local function tryDocModule(source)
    if not source.module then
        return
    end
    return collectRequire('require', source.module, guide.getUri(source))
end

local function buildEnumChunk(docType, name, uri)
    if not docType then
        return nil
    end
    local enums = {}
    local types = {}
    local lines = {}
    for _, tp in ipairs(vm.getDefs(docType)) do
        types[#types+1] = vm.getInfer(tp):view(guide.getUri(docType))
        if tp.type == 'doc.type.string'
        or tp.type == 'doc.type.integer'
        or tp.type == 'doc.type.boolean'
        or tp.type == 'doc.type.code' then
            enums[#enums+1] = tp
        end
        local comment = tryDocClassComment(tp)
        if comment then
            for line in util.eachLine(comment) do
                lines[#lines+1] = ('-- %s'):format(line)
            end
        end
    end
    if #enums == 0 then
        return nil
    end
    lines[#lines+1] = ('%s:'):format(name)
    for _, enum in ipairs(enums) do
        local enumDes = ('   %s %s'):format(
                (enum.default    and '->')
            or  (enum.additional and '+>')
            or  ' |',
            vm.viewObject(enum, uri)
        )
        if enum.comment then
            local first = true
            local len = #enumDes
            for comm in enum.comment:gmatch '[^\r\n]+' do
                if first then
                    first = false
                    enumDes = ('%s -- %s'):format(enumDes, comm)
                else
                    enumDes = ('%s\n%s -- %s'):format(enumDes, (' '):rep(len), comm)
                end
            end
        end
        lines[#lines+1] = enumDes
    end
    return table.concat(lines, '\n')
end

local function getBindEnums(source, docGroup)
    if source.type ~= 'function' then
        return
    end

    local uri = guide.getUri(source)
    local mark = {}
    local chunks = {}
    local returnIndex = 0
    for _, doc in ipairs(docGroup) do
        if     doc.type == 'doc.param' then
            local name = doc.param[1]
            if name == '...' then
                name = '...(param)'
            end
            if mark[name] then
                goto CONTINUE
            end
            mark[name] = true
            chunks[#chunks+1] = buildEnumChunk(doc.extends, name, uri)
        elseif doc.type == 'doc.return' then
            for _, rtn in ipairs(doc.returns) do
                returnIndex = returnIndex + 1
                local name = rtn.name and rtn.name[1] or ('return #%d'):format(returnIndex)
                if name == '...' then
                    name = '...(return)'
                end
                if mark[name] then
                    goto CONTINUE
                end
                mark[name] = true
                chunks[#chunks+1] = buildEnumChunk(rtn, name, uri)
            end
        end
        ::CONTINUE::
    end
    if #chunks == 0 then
        return nil
    end
    return table.concat(chunks, '\n\n')
end

local function tryDocFieldUpComment(source)
    if source.type ~= 'doc.field' then
        return
    end
    if not source.bindGroup then
        return
    end
    local comment = getBindComment(source)
    return comment
end

local function getFunctionComment(source)
    local docGroup = source.bindDocs

    local hasReturnComment = false
    for _, doc in ipairs(source.bindDocs) do
        if doc.type == 'doc.return' and doc.comment then
            hasReturnComment = true
            break
        end
    end

    local uri = guide.getUri(source)
    local md = markdown()
    for _, doc in ipairs(docGroup) do
        if     doc.type == 'doc.comment' then
            local comment = normalizeComment(doc.comment.text, uri)
            md:add('md', comment)
        elseif doc.type == 'doc.param' then
            if doc.comment then
                md:add('md', ('@*param* `%s` — %s'):format(
                    doc.param[1],
                    doc.comment.text
                ))
            end
        elseif doc.type == 'doc.return' then
            if hasReturnComment then
                local name = {}
                for _, rtn in ipairs(doc.returns) do
                    if rtn.name then
                        name[#name+1] = rtn.name[1]
                    end
                end
                if doc.comment then
                    if #name == 0 then
                        md:add('md', ('@*return* — %s'):format(doc.comment.text))
                    else
                        md:add('md', ('@*return* `%s` — %s'):format(table.concat(name, ','), doc.comment.text))
                    end
                else
                    if #name == 0 then
                        md:add('md', '@*return*')
                    else
                        md:add('md', ('@*return* `%s`'):format(table.concat(name, ',')))
                    end
                end
            end
        elseif doc.type == 'doc.overload' then
            md:splitLine()
        end
        ::CONTINUE::
    end

    local enums = getBindEnums(source, docGroup)
    md:add('lua', enums)
    return md
end

local function tryDocComment(source)
    if not source.bindDocs then
        return
    end
    if source.type ~= 'function' then
        local comment = lookUpDocComments(source, source.bindDocs)
        return comment
    end
    return getFunctionComment(source)
end

local function tryDocOverloadToComment(source)
    if source.type ~= 'doc.type.function' then
        return
    end
    local doc = source.parent
    if doc.type ~= 'doc.overload'
    or not doc.bindSource then
        return
    end
    local md = tryDocComment(doc.bindSource)
    if md then
        return md
    end
end

local function tyrDocParamComment(source)
    if source.type == 'setlocal'
    or source.type == 'getlocal' then
        source = source.node
    end
    if source.type ~= 'local' then
        return
    end
    if source.parent.type ~= 'funcargs' then
        return
    end
    if not source.bindDocs then
        return
    end
    for i = #source.bindDocs, 1, -1 do
        local doc = source.bindDocs[i]
        if  doc.type == 'doc.param'
        and doc.param[1] == source[1]
        and doc.comment then
            return doc.comment.text
        end
    end
end

return function (source)
    if source.type == 'string' then
        return asString(source)
    end
    if source.type == 'field' then
        source = source.parent
    end
    return tryDocOverloadToComment(source)
        or tryDocFieldUpComment(source)
        or tyrDocParamComment(source)
        or tryDocComment(source)
        or tryDocClassComment(source)
        or tryDocModule(source)
end
