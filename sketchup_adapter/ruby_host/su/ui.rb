# UI module emulation. Everything visible is forwarded to the IngeTrazo side
# through Bridge (JSON lines over the real stdout).

MB_OK = 0; MB_OKCANCEL = 1; MB_ABORTRETRYIGNORE = 2; MB_YESNOCANCEL = 3; MB_YESNO = 4; MB_RETRYCANCEL = 5; MB_MULTILINE = 16
SB_PROMPT = 0; SB_VCB_LABEL = 1; SB_VCB_VALUE = 2
IDOK = 1; IDCANCEL = 2; IDABORT = 3; IDRETRY = 4; IDIGNORE = 5; IDYES = 6; IDNO = 7
MF_ENABLED = 0; MF_GRAYED = 1; MF_DISABLED = 2; MF_CHECKED = 8; MF_UNCHECKED = 0
TB_HIDDEN = 0; TB_VISIBLE = 1; TB_NEVER_SHOWN = -1
CONSTRAIN_MODIFIER_KEY = 16; COPY_MODIFIER_KEY = 17; ALT_MODIFIER_KEY = 18
CONSTRAIN_MODIFIER_MASK = 4; COPY_MODIFIER_MASK = 8; ALT_MODIFIER_MASK = 32
VK_SHIFT = 16; VK_CONTROL = 17; VK_MENU = 18; VK_ESCAPE = 27; VK_RETURN = 13; VK_DELETE = 46
VK_SPACE = 32
VK_LEFT = 37; VK_UP = 38; VK_RIGHT = 39; VK_DOWN = 40
MK_LBUTTON = 1; MK_RBUTTON = 2; MK_SHIFT = 4; MK_CONTROL = 8; MK_ALT = 32

module Sketchup
  class Console
    def show; Bridge.notify('console_action','action'=>'show'); true; end
    def hide; Bridge.notify('console_action','action'=>'hide'); true; end
    def clear; Bridge.notify('console_action','action'=>'clear'); true; end
    def visible?; !!Bridge.call('console_visible'); end
    def write(value)
      text=value.to_s
      Bridge.notify('console_text','text'=>text)
      text.bytesize
    end
    def print(*values); values.each { |value| write(value) }; nil; end
    def puts(*values); (values.empty? ? [''] : values).each { |value| write(value.to_s+"\n") }; nil; end
    def flush; self; end
  end
end
SKETCHUP_CONSOLE = Sketchup::Console.new unless defined?(SKETCHUP_CONSOLE)

module UI
  @timers = {}
  @timer_seq = 0
  @context_handlers = []
  @commands = []
  @context_commands = {}
  @context_command_seq = 0
  @building_context_menu = false
  @toolbars = []
  @menus = {}

  class << self
    attr_reader :timers, :context_handlers, :commands, :toolbars

    def register_context_command(command)
      @context_command_seq += 1
      command.assign_id(1_000_000 + @context_command_seq)
      @context_commands[command.id] = command
      command.id
    end

    def command(id)
      key = id.to_i
      @context_commands[key] || (@commands[key - 1] if key.positive?)
    end

    def context_building?; @building_context_menu; end

    def with_context_menu
      previous = @building_context_menu
      @building_context_menu = true
      yield
    ensure
      @building_context_menu = previous
    end

    def messagebox(msg, type = MB_OK, _title = nil)
      r = Bridge.call("messagebox", "text" => msg.to_s, "type" => type.to_i)
      r.to_i
    end
    def inputbox(prompts, defaults = [], lists_or_title = nil, title = nil)
      r = Bridge.call("inputbox", "prompts" => Array(prompts), "defaults" => Array(defaults).map(&:to_s),
                                  "title" => (title || (lists_or_title.is_a?(String) ? lists_or_title : "")).to_s)
      return false unless r
      # Native inputbox preserves numeric default types. The browser/Qt
      # transport carries text, so recover those types at this API boundary.
      Array(r).each_with_index.map do |value,index|
        case defaults[index]
        when Integer then Integer(value.to_s,10)
        when Float then Float(value.to_s)
        else value
        end
      end
    end
    def openpanel(title = "", dir = "", filter = ""); Bridge.call("openpanel", "title" => title.to_s, "dir" => dir.to_s, "filter" => filter.to_s); end
    def savepanel(title = "", dir = "", name = ""); Bridge.call("savepanel", "title" => title.to_s, "dir" => dir.to_s, "name" => name.to_s); end
    def select_directory(opts = {}); Bridge.call("select_directory", "title" => (opts[:title] || "").to_s); end
    def openURL(url); Bridge.notify("open_url", "url" => url.to_s); true; end
    def beep; true; end
    def refresh_inspectors; true; end
    def refresh_toolbars; true; end
    def show_inspector(_n); true; end
    def scale_factor(*_a); 1.0; end
    def set_cursor(id)
      Bridge.notify('cursor_set','id'=>id.to_i)
      true
    end
    def create_cursor(path,hot_x,hot_y)
      path=File.expand_path(path.to_s)
      raise ArgumentError,'Cursor image does not exist' unless File.file?(path)
      @cursor_ids ||= {}
      key=[path,hot_x.to_i,hot_y.to_i]
      return @cursor_ids[key] if @cursor_ids.key?(key)
      id=10000+@cursor_ids.length
      @cursor_ids[key]=id
      Bridge.notify('cursor_new','id'=>id,'path'=>path,'hotspot'=>[hot_x.to_i,hot_y.to_i])
      id
    end
    def play_sound(_p); true; end
    def show_model_info(*_a); true; end
    def show_preferences(*_a); true; end
    def show_extension_manager; true; end
    def toolbar_names; @toolbars.map(&:name); end
    def toolbar(name); @toolbars.find { |t| t.name == name } || Toolbar.new(name); end

    def start_timer(seconds, repeat = false, &block)
      id = (@timer_seq += 1)
      @timers[id] = { at: Time.now.to_f + seconds.to_f, every: seconds.to_f, repeat: repeat, block: block }
      id
    end
    def stop_timer(id); @timers.delete(id); nil; end

    def run_due_timers
      now = Time.now.to_f
      # Capture the scheduled deadline along with identity: nested timer
      # dispatch may cancel, replace or reschedule an already-selected timer.
      due = @timers.select { |_, timer| timer[:at] <= now }.map { |id, timer| [id, timer, timer[:at]] }
      @running_timers ||= {}
      due.each do |id, timer, scheduled_at|
        next unless @timers[id].equal?(timer) && timer[:at] == scheduled_at
        next if @running_timers.key?(id) || timer[:at] > Time.now.to_f
        @running_timers[id] = timer
        begin
          if timer[:repeat]
            timer[:at] = Time.now.to_f + [timer[:every], 0.01].max
          else
            @timers.delete(id)
          end
          begin
            if defined?(Host) && Host.respond_to?(:with_extension_context)
              Host.with_extension_context { timer[:block].call }
            else
              timer[:block].call
            end
          rescue StandardError => e
            Sketchup.log_exc("timer", e)
          end
        ensure
          @running_timers.delete(id) if @running_timers[id].equal?(timer)
        end
      end
    end

    def next_timer_delay
      return nil if @timers.empty?
      [[@timers.values.map { |t| t[:at] }.min - Time.now.to_f, 0].max, 1.0].min
    end

    def menu(name = "Extensions")
      name = 'Extensions' if name.to_s.casecmp('Plugins').zero?
      @menus[name] ||= Menu.new(name)
    end
    def add_context_menu_handler(&block); @context_handlers << block; @context_handlers.length; end
  end

  class Command
    attr_accessor :tooltip, :status_bar_text, :small_icon, :large_icon, :menu_text, :large_icon, :extension
    attr_reader :proc, :id
    def initialize(text, register: true, &block)
      @menu_text = text
      @proc = block
      @validation = nil
      register = false if register && UI.context_building?
      if register
        UI.commands << self
        @id = UI.commands.length
      else
        UI.register_context_command(self)
      end
    end
    def assign_id(id); @id = id.to_i; end
    def set_validation_proc(&b); @validation = b; self; end
    def validation_state
      return MF_ENABLED unless @validation
      @validation.call
    rescue StandardError
      MF_ENABLED
    end
    def run; @proc.call if @proc; end
    def to_h
      { "id" => @id, "text" => @menu_text.to_s, "tooltip" => (@tooltip || @menu_text).to_s,
        "status" => @status_bar_text.to_s, "small_icon" => @small_icon.to_s, "large_icon" => @large_icon.to_s }
    end
  end

  class Toolbar
    include Enumerable
    attr_reader :name, :items
    def initialize(name); @name = name; @items = []; @visible=false; @shown=false; UI.toolbars << self; end
    def add_item(cmd); @items << cmd; self; end
    def add_separator; @items << :separator; self; end
    def each(&b); @items.each(&b); end
    def show; @visible=true;@shown=true;Bridge.notify("toolbar", "name" => @name, "items" => @items.map { |c| c == :separator ? { "separator" => true } : c.to_h }); true; end
    def hide; @visible=false;Bridge.notify('toolbar_visibility','name'=>@name,'visible'=>false);true;end
    def restore; show; end
    def visible?; @visible; end
    def get_last_state; @shown ? (@visible ? TB_VISIBLE : TB_HIDDEN) : TB_NEVER_SHOWN; end
    def count; @items.length; end
  end

  class Menu
    attr_reader :items, :name
    def initialize(name, context: false); @name = name; @items = []; @context = context; end
    def add_item(cmd_or_text, &block)
      if cmd_or_text.is_a?(Command)
        @items << { cmd: cmd_or_text }
      else
        c = Command.new(cmd_or_text.to_s, register: !@context, &block)
        @items << { cmd: c }
      end
      @items.length
    end
    def add_submenu(text, _index = nil); m = Menu.new(text, context: @context); @items << { sub: m }; m; end
    def add_separator; @items << { sep: true }; true; end
    def set_validation_proc(item_id, &b)
      it = @items[item_id - 1]
      it[:cmd].set_validation_proc(&b) if it && it[:cmd]
      true
    end
    def to_h
      { "name" => @name, "items" => @items.map do |it|
        if it[:sep] then { "separator" => true }
        elsif it[:sub] then { "submenu" => it[:sub].to_h }
        else
          c = it[:cmd]
          st = c.validation_state
          { "id" => c.id, "text" => c.menu_text.to_s, "enabled" => (st & (MF_GRAYED | MF_DISABLED)) == 0,
            "checked" => (st & MF_CHECKED) != 0 }
        end
      end }
    end
  end

  class HtmlDialog
    STYLE_WINDOW = 0; STYLE_DIALOG = 1; STYLE_UTILITY = 2
    @all = {}
    class << self; attr_reader :all; end
    attr_reader :id, :callbacks, :options
    def initialize(opts = {})
      @options = opts
      @id = (HtmlDialog.all.length + 1)
      HtmlDialog.all[@id] = self
      @callbacks = {}
      @visible = false
      @size = [(opts[:width] || 400).to_i, (opts[:height] || 400).to_i]
      @on_closed = nil
      Bridge.notify("dialog_new", "id" => @id, "title" => opts[:dialog_title].to_s,
                                  "width" => @size[0], "height" => @size[1],
                                  "min_width" => (opts[:min_width] || 0).to_i, "min_height" => (opts[:min_height] || 0).to_i,
                                  "max_width" => opts[:max_width], "max_height" => opts[:max_height],
                                  "resizable" => opts.fetch(:resizable,true),
                                  "style" => (opts[:style] || STYLE_DIALOG).to_i,
                                  "pref_key" => opts[:preferences_key].to_s)
    end
    def set_file(path); Bridge.notify("dialog_file", "id" => @id, "path" => File.expand_path(path.to_s)); true; end
    def set_html(html); Bridge.notify("dialog_html", "id" => @id, "html" => html.to_s); true; end
    def set_url(u); Bridge.notify("dialog_url", "id" => @id, "url" => u.to_s); true; end
    def add_action_callback(name, &block); @callbacks[name.to_s] = block; true; end
    def remove_action_callback(name); @callbacks.delete(name.to_s); true; end
    def show; @visible = true; Bridge.notify("dialog_show", "id" => @id); true; end
    def show_modal; show; end
    def visible?; @visible; end
    def mark_closed!; @visible = false; @on_closed.call if @on_closed; end
    def bring_to_front; Bridge.notify("dialog_front", "id" => @id); true; end
    def close; @visible = false; Bridge.notify("dialog_close", "id" => @id); true; end
    def execute_script(js); Bridge.notify("exec_js", "id" => @id, "script" => js.to_s); true; end
    def set_size(w, h); @size = [w.to_i, h.to_i]; Bridge.notify("dialog_size", "id" => @id, "w" => @size[0], "h" => @size[1]); true; end
    def get_size; @size.dup; end
    def remember_size(w, h); @size = [w.to_i, h.to_i]; end
    def set_position(x, y); Bridge.notify("dialog_pos", "id" => @id, "x" => x.to_i, "y" => y.to_i); true; end
    def get_position; [0, 0]; end
    def center; true; end
    def set_on_closed(&b); @on_closed = b; true; end
    def set_can_close(&_b); true; end
    def set_can_close_callback(&_b); true; end
  end

  class WebDialog < HtmlDialog
    def allow_actions_from_host(hostname)
      hostname=hostname.to_s.downcase
      raise ArgumentError,'Expected a hostname' unless hostname.match?(/\A[a-z0-9.-]+\z/)
      Bridge.notify('dialog_allow_host','id'=>@id,'hostname'=>hostname)
      true
    end
    def initialize(title = "", _s = true, _k = nil, w = 400, h = 400, *_a)
      super(dialog_title: title, width: w, height: h)
    end
  end

  class ActionContext; end
end
