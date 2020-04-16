--------------
-- Handling markup transformation.
-- Currently just does Markdown, but this is intended to
-- be the general module for managing other formats as well.

local doc = require 'ldoc.doc'
local utils = require 'pl.utils'
local stringx = require 'pl.stringx'
local prettify = require 'ldoc.prettify'
local quit, concat, lstrip = utils.quit, table.concat, stringx.lstrip
local markup = {}

local backtick_references

-- inline <references> use same lookup as @see
local function resolve_inline_references (ldoc, txt, item, plain)
   local do_escape = not plain and not ldoc.dont_escape_underscore
   local res = (txt:gsub('@{([^}]-)}',function (name)
      if name:match '^\\' then return '@{'..name:sub(2)..'}' end
      local qname,label = utils.splitv(name,'%s*|')
      if not qname then
         qname = name
      end
      local ref, err
      local custom_ref, refname = utils.splitv(qname,':')
      if custom_ref and ldoc.custom_references then
         custom_ref = ldoc.custom_references[custom_ref]
         if custom_ref then
            ref,err = custom_ref(refname)
         end
      end
      if not ref then
         ref,err = markup.process_reference(qname)
      end
      if not ref then
         err = err .. ' ' .. qname
         if item and item.warning then item:warning(err)
         else
           io.stderr:write('nofile error: ',err,'\n')
         end
         return '???'
      end
      if not label then
         label = ref.label
      end
      if label and do_escape  then -- a nastiness with markdown.lua and underscores
         label = label:gsub('_','\\_')
      end
      local html = ldoc.href(ref) or '#'
      label = ldoc.escape(label or qname)
      local res = ('<a href="%s">%s</a>'):format(html,label)
      return res
   end))
   if backtick_references then
      res  = res:gsub('`([^`]+)`',function(name)
         local ref,err = markup.process_reference(name)
         local label = name
         if name and do_escape then
            label = name:gsub('_', '\\_')
         end
         label = ldoc.escape(label)
         if ref then
            return ('<a href="%s">%s</a>'):format(ldoc.href(ref),label)
         else
            return '<code>'..label..'</code>'
         end
      end)
   end
   return res
end

-- for readme text, the idea here is to create module sections at ## so that
-- they can appear in the contents list as a ToC.
function markup.add_sections(F, txt)
   local sections, L, first = {}, 1, true
   local title_pat
   local lstrip = stringx.lstrip
   for line in stringx.lines(txt) do
      if first then
         local level,header = line:match '^(#+)%s*(.+)'
         if level then
            level = level .. '#'
         else
            level = '##'
         end
         title_pat = '^'..level..'([^#]%s*.+)'
         title_pat = lstrip(title_pat)
         first = false
         F.display_name = header
      end
      local title = line:match (title_pat)
      if title then
         --- Windows line endings are the cockroaches of text
         title = title:gsub('\r$','')
         -- Markdown allows trailing '#'...
         title = title:gsub('%s*#+$','')
         sections[L] = F:add_document_section(lstrip(title))
      end
      L = L + 1
   end
   F.sections = sections
   return txt
end

local function indent_line (line)
   line = line:gsub('\t','    ') -- support for barbarians ;)
   local indent = #line:match '^%s*'
   return indent,line
end

local function blank (line)
   return not line:find '%S'
end

local global_context, local_context

-- before we pass Markdown documents to markdown/discount, we need to do three things:
-- - resolve any @{refs} and (optionally) `refs`
-- - any @lookup directives that set local context for ref lookup
-- - insert any section ids which were generated by add_sections above
-- - prettify any code blocks

local function process_multiline_markdown(ldoc, txt, F, filename, deflang)
   local res, L, append = {}, 0, table.insert
   local err_item = {
      warning = function (self,msg)
         io.stderr:write(filename..':'..L..': '..msg,'\n')
      end
   }
   local get = stringx.lines(txt)
   local getline = function()
      L = L + 1
      return get()
   end
   local function pretty_code (code, lang)
      code = concat(code,'\n')
      if code ~= '' then
         local err
         -- If we omit the following '\n', a '--' (or '//') comment on the
         -- last line won't be recognized.
         code, err = prettify.code(lang,filename,code..'\n',L,false)
         code = resolve_inline_references(ldoc, code, err_item,true)
         append(res,'<pre>')
         append(res, code)
         append(res,'</pre>')
      else
         append(res,code)
      end
   end
   local indent,start_indent
   local_context = nil
   local line = getline()
   while line do
      local name = line:match '^@lookup%s+(%S+)'
      if name then
         local_context = name .. '.'
         line = getline()
      end
      local fence = line:match '^```(.*)'
      if prettify.prettifier ~= 'none' and fence then
         local plain = fence==''
         line = getline()
         local code = {}
         while not line:match '^```' do
            if not plain then
               append(code, line)
            else
               append(res, '     '..line)
            end
            line = getline()
         end
         pretty_code (code,fence)
         line = getline() -- skip fence
         if not line then break end
      end
      indent, line = indent_line(line)
      if prettify.prettifier ~= 'none' and indent >= 4 then -- indented code block
         local code = {}
         local plain
         while indent >= 4 or blank(line) do
            if not start_indent then
               start_indent = indent
               if line:match '^%s*@plain%s*$' then
                  plain = true
                  line = getline()
               end
            end
            if not plain then
               append(code,line:sub(start_indent + 1))
            else
               append(res,line)
            end
            line = getline()
            if line == nil then break end
            indent, line = indent_line(line)
         end
         start_indent = nil
         while #code > 1 and blank(code[#code]) do  -- trim blank lines.
           table.remove(code)
         end
         pretty_code (code,deflang)
      else
         local section = F and F.sections[L]
         if section then
            append(res,('<a name="%s"></a>'):format(section))
         end
         line = resolve_inline_references(ldoc, line, err_item)
         append(res,line)
         line = getline()
      end
   end
   res = concat(res,'\n')
   return res
end


-- Handle markdown formatters
-- Try to get the one the user has asked for, but if it's not available,
-- try all the others we know about.  If they don't work, fall back to text.

local function generic_formatter(format)
   local ok, f = pcall(require, format)
   return ok and f
end


local formatters =
{
   markdown = function(format)
      local ok, markdown = pcall(require, 'markdown')
      if not ok then
         print('format: using built-in markdown')
         ok, markdown = pcall(require, 'ldoc.markdown')
      end
      return ok and markdown
   end,
   discount = function(format)
      local ok, markdown = pcall(require, 'discount')
      if ok then
         if 'function' == type(markdown) then
            -- lua-discount by A.S. Bradbury, https://luarocks.org/modules/luarocks/lua-discount
         elseif 'table' == type(markdown) and ('function' == type(markdown.compile) or 'function' == type(markdown.to_html)) then
            -- discount by Craig Barnes, https://luarocks.org/modules/craigb/discount
            -- result of apt-get install lua-discount (links against libmarkdown2)
            local mysterious_debian_variant = markdown.to_html ~= nil
            markdown = markdown.compile or markdown.to_html
            return function(text)
               local result, errmsg = markdown(text)
               if result then
                  if mysterious_debian_variant then
                     return result
                  else
                     return result.body
                  end
               else
                  io.stderr:write('LDoc discount failed with error ',errmsg)
                  io.exit(1)
               end
            end
         else
            ok = false
         end
      end
      if not ok then
         print('format: using built-in markdown')
         ok, markdown = pcall(require, 'ldoc.markdown')
      end
      return ok and markdown
   end,
   lunamark = function(format)
      local ok, lunamark = pcall(require, format)
      if ok then
         local writer = lunamark.writer.html.new()
         local parse = lunamark.reader.markdown.new(writer,
                                                    { smart = true })
         return function(text) return parse(text) end
      end
   end
}


local function get_formatter(format)
   local used_format = format
   local formatter = (formatters[format] or generic_formatter)(format)
   if not formatter then -- try another equivalent processor
      for name, f in pairs(formatters) do
         formatter = f(name)
         if formatter then
            print('format: '..format..' not found, using '..name)
            used_format = name
            break
         end
      end
   end
   return formatter, used_format
end

local function text_processor(ldoc)
   return function(txt,item)
      if txt == nil then return '' end
      -- hack to separate paragraphs with blank lines
      txt = txt:gsub('\n\n','\n<p>')
      return resolve_inline_references(ldoc, txt, item, true)
   end
end

local plain_processor

local function markdown_processor(ldoc, formatter)
   return function (txt,item,plain)
      if txt == nil then return '' end
      if plain then
         if not plain_processor then
            plain_processor = text_processor(ldoc)
         end
         return plain_processor(txt,item)
      end
      local is_file = utils.is_type(item,doc.File)
      local is_module = not file and item and doc.project_level(item.type)
      if is_file or is_module then
        local deflang = 'lua'
        if ldoc.parse_extra and ldoc.parse_extra.C then
            deflang = 'c'
        end
        if is_module then
            txt = process_multiline_markdown(ldoc, txt, nil, item.file.filename, deflang)
        else
            txt = process_multiline_markdown(ldoc, txt, item, item.filename, deflang)
        end
      else
         txt = resolve_inline_references(ldoc, txt, item)
      end
      txt = formatter(txt)
      -- We will add our own paragraph tags, if needed.
      return (txt:gsub('^%s*<p>(.+)</p>%s*$','%1'))
   end
end

local function get_processor(ldoc, format)
   if format == 'plain' then return text_processor(ldoc) end

   local formatter,actual_format = get_formatter(format)
   if formatter then
      markup.plain = false
      -- AFAIK only markdown.lua has underscore-in-identifier problem...
      if ldoc.dont_escape_underscore ~= nil then
         ldoc.dont_escape_underscore = actual_format ~= 'markdown'
      end
      return markdown_processor(ldoc, formatter)
   end

   print('format: '..format..' not found, falling back to text')
   return text_processor(ldoc)
end


function markup.create (ldoc, format, pretty, user_keywords)
   local processor
   markup.plain = true
   if format == 'backtick' then
      ldoc.backtick_references = true
      format = 'plain'
   end
   backtick_references = ldoc.backtick_references
   global_context = ldoc.package and ldoc.package .. '.'
   prettify.set_prettifier(pretty)
   prettify.set_user_keywords(user_keywords)

   markup.process_reference = function(name,istype)
      if local_context == 'none.' and not name:match '%.' then
         return nil,'not found'
      end
      local mod = ldoc.single or ldoc.module or ldoc.modules[1]
      local ref,err = mod:process_see_reference(name, ldoc.modules, istype)
      if ref then return ref end
      if global_context then
         local qname = global_context .. name
         ref = mod:process_see_reference(qname, ldoc.modules, istype)
         if ref then return ref end
      end
      if local_context then
         local qname = local_context .. name
         ref = mod:process_see_reference(qname, ldoc.modules, istype)
         if ref then return ref end
      end
      -- note that we'll return the original error!
      return ref,err
   end

   markup.href = function(ref)
      return ldoc.href(ref)
   end

   processor = get_processor(ldoc, format)
   if not markup.plain and backtick_references == nil then
      backtick_references = true
   end

   markup.resolve_inline_references = function(txt, errfn)
      return resolve_inline_references(ldoc, txt, errfn, markup.plain)
   end
   markup.processor = processor
   prettify.resolve_inline_references = function(txt, errfn)
      return resolve_inline_references(ldoc, txt, errfn, true)
   end
   return processor
end

return markup
