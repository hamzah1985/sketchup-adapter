# SketchUp adapter host for IngeTrazo.
#
# Runs unmodified SketchUp extensions (loaders + their Ruby support files)
# on an emulated SketchUp API, and talks JSON lines with the
# IngeTrazo plugin: dialog/toolbar/messagebox traffic, the user's selection,
# placements, and the resulting geometry.
#
#   ruby host.rb <plugins_dir> <loader-list-json>
#
# <plugins_dir> holds the extension loaders and their support directories.
require "json"
require "digest"

PROTO_OUT = $stdout.dup
PROTO_OUT.binmode
PROTO_OUT.sync = true
$stdout.reopen($stderr) # plugin `puts` goes to the log, never the protocol
$stdin.binmode

module Bridge
  @seq = 0
  @queue = []
  class << self
    attr_reader :queue
    def send_msg(h); PROTO_OUT.write(JSON.generate(h) + "\n"); end
    def notify(op, data = {}); send_msg({ "op" => op }.merge(data)); end

    # Synchronous request to IngeTrazo (message boxes, file panels). Other
    # traffic that arrives meanwhile is queued for the main loop.
    def call(fn, data = {})
      id = (@seq += 1)
      send_msg({ "op" => "call", "id" => id, "fn" => fn }.merge(data))
      loop do
        line = $stdin.gets
        exit(0) if line.nil?
        msg = JSON.parse(line) rescue next
        return msg["value"] if msg["op"] == "reply" && msg["id"] == id
        @queue << msg
      end
    end

    def place_component(defn)
      Host.pending_place(defn)
    end
  end
end

here = File.dirname(File.expand_path(__FILE__))
require File.join(here, "su", "geom")
require File.join(here, "su", "entities")
require File.join(here, "su", "model")
require File.join(here, "su", "ui")
require File.join(here, "su", "extras")
require File.join(here, "su", "interaction")
require File.join(here, "compatibility")
require File.join(here, "transactions")
require File.join(here, "su", "geometry_services")
require File.join(here, "su", "events")
require File.join(here, "topology")
$LOAD_PATH.unshift(File.join(here, "stubs"))

module Host
  class GenerationCancelled < Exception; end
  INCH = 0.0254
  @rid_map = {}      # ruby entity id -> entity (root containers we reported)
  @sent_digest = {}  # rid -> digest of the last payload sent
  @host_faces = {}   # ruby face id -> ingetrazo face token
  @host_edges = []
  @pending = {}      # definition id -> definition awaiting placement
  @tools = {}        # IngeTrazo tool id -> SketchUp extension tool
  @tool_ids = {}     # extension tool object id -> IngeTrazo tool id
  @tool_seq = 0
  @active_tool_id = nil
  @pick_targets = {}
  @pick_entities = nil
  @proxy_rids = {}
  @proxy_group_uids = {}

  class << self
    attr_reader :rid_map, :active_tool_id

    def check_generation_cancel!
      path=ENV['INGETRAZO_SKETCHUP_CANCEL_FILE']
      return unless path && @active_tool_id
      raise GenerationCancelled if File.read(path,encoding:'US-ASCII').strip == @active_tool_id.to_s
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def m(p); [p.x * INCH, p.y * INCH, p.z * INCH]; end

    def xform_out(t)
      a = t.to_a
      a[12] *= INCH; a[13] *= INCH; a[14] *= INCH
      a
    end

    def xform_in(a)
      a = a.map(&:to_f)
      a[12] /= INCH; a[13] /= INCH; a[14] /= INCH
      Geom::Transformation.new(a)
    end

    # ---------------------------------------------------------------- export
    def material_attrs(mat, cache)
      return nil unless mat
      mat = Sketchup.active_model.materials[mat] if mat.is_a?(String)
      return nil unless mat
      cache[mat.object_id] ||= begin
        h = { "mat" => mat.name.to_s }
        c = mat.color || Sketchup::Color.new(255, 255, 255)
        h["color"] = [c.red / 255.0, c.green / 255.0, c.blue / 255.0]
        h["opacity"] = mat.alpha.to_f if mat.alpha.to_f < 0.999
        if mat.texture && File.file?(mat.texture.filename)
          h["texture"] = { "path" => mat.texture.filename, "sw" => mat.texture.width * INCH,
                           "sh" => mat.texture.height * INCH }
        end
        h
      end
    end

    # Per-face affine UV map, IngeTrazo's "uvw": u = gu·p + cu (p in metres).
    def face_uvw(face, pts, front = true)
      return nil if pts.length < 3
      n = face.normal
      p0 = pts[0]
      p1 = pts.max_by { |p| p.distance(p0) }
      p2 = pts.max_by { |p| ((p1 - p0).cross(p - p0)).length }
      e1 = p1 - p0; e2 = p2 - p0
      return nil if e1.cross(e2).length < 1e-9
      uv0 = face.uv_for(p0, front); uv1 = face.uv_for(p1, front); uv2 = face.uv_for(p2, front)
      e1m = e1 * INCH; e2m = e2 * INCH
      a11 = e1m.dot(e1m); a12 = e1m.dot(e2m); a22 = e2m.dot(e2m)
      det = a11 * a22 - a12 * a12
      return nil if det.abs < 1e-18
      grad = lambda do |d1, d2|
        # gu = s*e1 + t*e2 with gu·e1=d1, gu·e2=d2
        s = (d1 * a22 - d2 * a12) / det
        t = (d2 * a11 - d1 * a12) / det
        e1m * s + e2m * t
      end
      gu = grad.call(uv1.x - uv0.x, uv2.x - uv0.x)
      gv = grad.call(uv1.y - uv0.y, uv2.y - uv0.y)
      p0m = Geom::Vector3d.new(*m(p0))
      [gu.x, gu.y, gu.z, uv0.x - gu.dot(p0m), gv.x, gv.y, gv.z, uv0.y - gv.dot(p0m)]
    end

    def export_container(root)
      protos = []
      index = {}
      cache = {}
      build = lambda do |defn, inherited, name|
        key = [defn.object_id, inherited ? inherited.object_id : 0]
        return index[key] if index.key?(key)
        idx = protos.length
        index[key] = idx
        pr = { "name" => name.to_s, "faces" => [], "edges" => [], "soft_edges" => [], "children" => [] }
        pr['definition_key']=defn.entityID
        pr['def_attrs'] = defn.attribute_dictionaries ? defn.attribute_dictionaries.to_h : {}
        sections = defn.entities.grep(Sketchup::SectionPlane).select(&:valid?)
        pr['section_planes'] = sections.map(&:bridge_data) unless sections.empty?
        protos << pr
        defn.entities.to_a.each do |e|
          next unless e.valid?
          case e
          when Sketchup::Face
            next if e.respond_to?(:hidden?) && e.hidden?
            unless e.normal.valid? && e.outer_loop.vertices.map { |v| v.position.to_a }.uniq.length >= 3
              pr['dropped_zero_area_faces'] = pr.fetch('dropped_zero_area_faces', 0) + 1
              next
            end
            mat = e.material || inherited
            loops = e.loops.map { |l| l.points }
            # Winding belongs to the geometry, never to the painted side.
            # A back-only finish must not turn an outward solid inside out.
            attrs = material_attrs(mat, cache)
            attrs = attrs ? attrs.dup : {}
            attrs['layer']=e.layer.name unless %w[Layer0 Untagged].include?(e.layer.name)
            original_attrs = e.get_attribute("_ingetrazo_bridge", "face_attrs")
            restored = original_attrs.is_a?(Hash) && e.get_attribute('_ingetrazo_bridge','restored_material_stamp') == face_material_stamp(e)
            if original_attrs.is_a?(Hash)
              attrs = mat && !restored ? original_attrs.reject { |k, _| %w[mat color opacity texture].include?(k) }.merge(attrs) : original_attrs.dup
            end
            if attrs["texture"] && !restored && (mat || !original_attrs.is_a?(Hash))
              uvw = face_uvw(e, loops[0])
              attrs["texture"] = attrs["texture"].merge("uvw" => uvw) if uvw
            end
            if e.back_material && !restored
              back = material_attrs(e.back_material, cache).dup
              if back['texture']
                uvw = face_uvw(e, loops[0], false)
                back['texture'] = back['texture'].merge('uvw'=>uvw) if uvw
              end
              attrs['back'] = back
            end
            if e.attribute_dictionaries
              d = e.attribute_dictionaries.to_h.reject { |k, _| k == "_ingetrazo_bridge" }
              attrs["wc_attrs"] = d unless d.empty?
            end
            pr["faces"] << [loops[0].map { |p| m(p) }, loops[1..-1].map { |h| h.map { |p| m(p) } }, attrs]
          when Sketchup::Edge
            pr["edges"] << [m(e.start.position), m(e.end.position)] if e.faces.empty? && !e.hidden?
            if e.soft? || e.smooth? || e.hidden?
              pr["soft_edges"] << [m(e.start.position), m(e.end.position)]
            end
          when Sketchup::Group, Sketchup::ComponentInstance
            child_mat = e.material || inherited
            cidx = build.call(e.definition, child_mat, e.name.to_s.empty? ? e.definition.name : e.name)
            pr["children"] << { "proto" => cidx, "xform" => xform_out(e.transformation),
                                "name" => e.name.to_s.empty? ? e.definition.name : e.name,
                                "component" => e.is_a?(Sketchup::ComponentInstance),
                                "attrs" => e.attribute_dictionaries ? e.attribute_dictionaries.to_h : {},
                                'layer'=>e.layer && !%w[Layer0 Untagged].include?(e.layer.name) ? e.layer.name : nil,
                                "hidden" => hidden_in_native_view?(e) }
          end
        end
        pr['mesh_digest']=Digest::SHA1.hexdigest(JSON.generate(pr.values_at('faces','edges','soft_edges','section_planes')))
        idx
      end
      root_idx = build.call(root.definition, root.material, root.name.to_s.empty? ? root.definition.name : root.name)
      materials = cache.values.map { |a| { "name" => a["mat"], "color" => a["color"], "texture" => a["texture"], "opacity" => a["opacity"] } }
      { "protos" => protos, "root" => root_idx, "xform" => xform_out(root.transformation),
        "hidden" => hidden_in_native_view?(root),
        "component" => root.is_a?(Sketchup::ComponentInstance),
        "name" => (root.name.to_s.empty? ? root.definition.name : root.name),
        'layer'=>root.layer && !%w[Layer0 Untagged].include?(root.layer.name) ? root.layer.name : nil,
        "attrs" => root.attribute_dictionaries ? root.attribute_dictionaries.to_h : {},
        "def_attrs" => root.definition.attribute_dictionaries ? root.definition.attribute_dictionaries.to_h : {},
        "materials" => materials }
    end

    def hidden_in_native_view?(entity)
      (entity.respond_to?(:hidden?) && entity.hidden?) ||
        (entity.respond_to?(:layer) && entity.layer && !entity.layer.visible?)
    end

    def export_definition(defn)
      tmp = Sketchup::ComponentInstance.new(defn, Geom::Transformation.new)
      out = export_container(tmp)
      defn.instances_list.delete(tmp)
      out["name"] = defn.name
      out
    end

    # ------------------------------------------------------------ model sync
    # After every inbound message: report root containers that appeared,
    # changed or vanished, and host faces the builder erased.
    def sync
      model = Sketchup.active_model
      return if model.operation_depth > 0
      surface_patch = model.active_view.native_surface_patch
      sync_native_surfaces
      sync_native_edges
      sync_native_guides
      roots = model.entities.to_a.select { |e| (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && e.valid? }
      loose = adapter_loose_root(model)
      roots << loose if loose
      seen = {}
      roots.each do |r|
        rid = r.entityID
        payload = export_container(r)
        # Interactive plugins often allocate an empty helper group before
        # beginning their operation. Publishing it would create an extra native
        # history entry and leave an empty group behind after Undo.
        unless @rid_map.key?(rid)
          has_content=payload['protos'].any? { |prototype|
            !prototype['faces'].empty? || !prototype['edges'].empty? ||
              !Array(prototype['section_planes']).empty?
          }
          next unless has_content
        end
        seen[rid] = true
        @rid_map[rid] = r
        dig = Digest::SHA1.hexdigest(JSON.generate(payload))
        next if @sent_digest[rid] == dig
        @sent_digest[rid] = dig
        data = {"rid"=>rid, "payload"=>payload}
        data['surface_patch'] = surface_patch if surface_patch
        surface_patch = nil
        Bridge.notify('upsert',data)
      end
      # Selected non-extension groups are private Ruby proxies. If an
      # extension edits one (Hide, cabinet resizers, etc.), return just that
      # changed proxy to its matching IngeTrazo group.
      (@proxy_groups || []).each do |g|
        rid = g.entityID
        unless g.valid?
          Bridge.notify('removed','rid'=>rid)
          @rid_map.delete(rid);@sent_digest.delete(rid);@proxy_rids.delete(rid)
          uid=@proxy_group_uids.delete(rid)
          @uid_to_rid.delete(uid) if uid && @uid_to_rid
          next
        end
        seen[rid] = true
        @rid_map[rid] = g
        payload = export_container(g)
        dig = Digest::SHA1.hexdigest(JSON.generate(payload))
        next if @sent_digest[rid] == dig
        @sent_digest[rid] = dig
        Bridge.notify("upsert", "rid" => rid, "payload" => payload)
      end
      @proxy_groups.select!(&:valid?) if @proxy_groups
      Bridge.notify('surface_patch',surface_patch) if surface_patch
      (@rid_map.keys - seen.keys).each do |rid|
        @rid_map.delete(rid)
        @sent_digest.delete(rid)
        if @proxy_rids.delete(rid)
          uid = @proxy_group_uids.delete(rid)
          @uid_to_rid.delete(uid) if uid && @uid_to_rid
        else
          Bridge.notify("removed", "rid" => rid)
        end
      end
      # Splitting can leave live proxy fragments after the original Ruby face
      # is erased. Keep the token's record until its last fragment is gone so
      # later edits are reported; the native preflight will reject stale
      # targets rather than silently accepting an untracked edit.
      surviving_tokens=model.entities.faces.select(&:valid?).filter_map do |face|
        face.instance_variable_get(:@adapter_surface_token)
      end.to_h { |token| [token,true] }
      @host_faces.keys.each do |fid|
        f = @host_faces[fid][:face]
        next if f.valid?
        next if surviving_tokens[@host_faces[fid][:token]]
        Bridge.notify("face_erased", "token" => @host_faces[fid][:token])
        @host_faces.delete(fid)
      end
    end

    def pending_place(defn)
      @pending[defn.entityID] = defn
      Bridge.notify("place", "def" => defn.entityID, "payload" => export_definition(defn))
    end

    # SketchUp's model.select_tool switches the current interaction tool.
    # IngeTrazo performs the hit testing and routes cursor/key events back to
    # this isolated Ruby process through JSON lines.
    def select_tool(tool)
      model = Sketchup.active_model
      return true if @switching_tool
      previous=@tools[@active_tool_id]
      if previous && !previous.equal?(tool)
        begin
          @switching_tool=true
          previous.deactivate(model.active_view) if previous.respond_to?(:deactivate)
        rescue StandardError=>error
          Sketchup.log_exc('extension tool switch',error)
        ensure
          @switching_tool=false
        end
      end
      if tool.nil?
        @active_tool_id = nil
        model.tools.set_active(21022, "SelectionTool")
        Bridge.notify("tool_select", "id" => nil, "name" => "Selection")
        return true
      end
      tid = @tool_ids[tool.object_id]
      if tid && tid == @active_tool_id
        Bridge.notify("tool_reset", "id" => tid)
        return true
      end
      # An activation has its own id even when the vendor reuses a tool
      # object. Late frames/cancellation from its previous run stay retired.
      @tool_seq += 1
      tid = @tool_seq
      @tool_ids[tool.object_id] = tid
      @tools[tid] = tool
      @active_tool_id = tid
      name = tool.class.name.to_s.empty? ? "Extension Tool" : tool.class.name.to_s
      model.tools.set_active(22000 + tid, name)
      @failed_tool_id = nil
      Bridge.notify("tool_select", "id" => tid, "name" => name, "title" => @command_title,
                                "claims_keys" => tool.respond_to?(:onKeyDown))
      true
    end

    def pick_proxy(snapshot, fallback_uid = nil)
      uid = (snapshot.is_a?(Hash) ? snapshot["uid"] : fallback_uid).to_s
      known=(@uid_to_rid || {})[uid]
      actual=known && @rid_map[known]
      return actual if actual && actual.valid?
      return @pick_targets[uid] if !uid.empty? && @pick_targets[uid]
      return nil unless snapshot.is_a?(Hash)
      @pick_entities ||= Sketchup::Entities.new(Sketchup.active_model)
      ent = build_pick_entity(snapshot, @pick_entities, 0)
      @pick_targets[uid] = ent unless uid.empty?
      ent
    rescue StandardError => e
      Sketchup.log_exc("cursor pick proxy", e)
      nil
    end

    def build_pick_entity(snapshot, entities, depth)
      return nil if depth > 24
      model = Sketchup.active_model
      name = snapshot["name"].to_s
      xf = snapshot["xform"] ? xform_in(snapshot["xform"]) : Geom::Transformation.new
      if snapshot["component"]
        @native_definition_cache ||= {}
        identity=snapshot['definition_key']
        content=snapshot.reject { |key,_| %w[uid xform hidden name attrs].include?(key) }
        definition_key=identity && [identity,Digest::SHA1.hexdigest(JSON.generate(content))]
        cached=definition_key && @native_definition_cache[definition_key]
        defn = cached || model.definitions.add(name.empty? ? "Bogdan Extension" : name)
        ent = entities.add_instance(defn, xf)
        target_entities = defn.entities
      else
        ent = entities.add_group
        ent.name = name
        ent.transformation = xf
        target_entities = ent.entities
      end
      ent.name = name unless name.empty?
      ent.layer=snapshot['layer'] if snapshot['layer']
      ent.hidden = !!snapshot["hidden"] if ent.respond_to?(:hidden=)
      (snapshot["def_attrs"] || {}).each do |dn, attrs|
        attrs.each { |k, v| ent.definition.set_attribute(dn, k, v) } if ent.respond_to?(:definition)
      end
      (snapshot["attrs"] || {}).each { |dn, attrs| attrs.each { |k, v| ent.set_attribute(dn, k, v) } }
      return ent if cached
      Array(snapshot["faces"]).each do |fd|
        outer, holes, attrs = fd
        pts = Array(outer).map { |p| Geom::Point3d.new(p[0] / INCH, p[1] / INCH, p[2] / INCH) }
        f = target_entities.add_face_raw(pts)
        next unless f
        Array(holes).each do |ring|
          verts = ring.map { |p| target_entities.vertex(Geom::Point3d.new(p[0] / INCH, p[1] / INCH, p[2] / INCH)) }
          f.add_hole(verts)
        end
        f.set_attribute("_ingetrazo_bridge", "face_attrs", attrs) if attrs.is_a?(Hash)
        restore_face_materials(f, attrs) if attrs.is_a?(Hash)
        f.layer=attrs['layer'] if attrs.is_a?(Hash) && attrs['layer']
      end
      Array(snapshot["edges"]).each do |a, b|
        entities_pair = [a, b].map { |p| Geom::Point3d.new(p[0] / INCH, p[1] / INCH, p[2] / INCH) }
        target_entities.add_line(*entities_pair)
      end
      Array(snapshot['soft_edges']).each do |a,b|
        av,bv = [a,b].map { |p| target_entities.find_vertex(Geom::Point3d.new(p.map { |v| v / INCH })) }
        e = av && bv && target_entities.edge_between(av,bv)
        e.soft = true if e
        e.smooth = true if e
      end
      Array(snapshot["children"]).each do |child|
        build_pick_entity(child, target_entities, depth + 1)
      end
      Array(snapshot['section_planes']).each do |data|
        point = Geom::Point3d.new(data['point'].map { |v| v / INCH })
        plane = target_entities.add_section_plane(point, Geom::Vector3d.new(data['normal']))
        plane.name = data['name'].to_s
        (data['attrs'] || {}).each { |dn, attrs| attrs.each { |k, v| plane.set_attribute(dn, k, v) } }
        plane.activate if data['active']
      end
      @native_definition_cache[definition_key]=defn if definition_key
      ent
    end

    def dispatch_tool_event(msg)
      id = msg["id"].to_i
      tool = @tools[id]
      # select_tool already deactivates the previous Ruby tool synchronously.
      # A delayed native notification must never run old callbacks against a
      # newly selected tool or its operation.
      unless tool && @active_tool_id == id
        # A callback can switch tools before the queued cancel is handled.
        # Do not abort the new tool's operation or report rollback as complete.
        Bridge.notify('tool_cancel_unconfirmed', 'tool'=>id) if msg['event']=='cancel'
        return
      end
      return if @failed_tool_id == id && !%w[cancel deactivate reset].include?(msg['event'])
      view = Sketchup.active_model.active_view
      input = msg["input"] || {}
      view.reset_interaction if %w[activate reset deactivate cancel].include?(msg['event'])
      target = pick_proxy(input["pick"], input["pick_uid"])
      Sketchup.silence_bridge_events do
        import_cursor_context(input['surface_context']) if input['surface_context']
        if input['edge_context']
          import_cursor_context(input['edge_context'])
          import_native_edges(input['edge_context'])
        end
        view.set_cursor_data(input, target)
      end
      x, y = (input["screen"] || [0, 0]).map(&:to_i)
      flags = input["flags"].to_i
      case msg["event"]
      when "activate"
        # SketchUp's Tool#activate has no arguments. Passing the active view
        # breaks tools whose callback is defined as `def activate` (for
        # example Pool Crafter's click-to-place tool).
        tool.activate if tool.respond_to?(:activate)
      when "deactivate"
        if tool.respond_to?(:deactivate)
          tool.deactivate(view)
        end
        @active_tool_id = nil if @active_tool_id == id
      when "cancel"
        begin
          tool.onCancel(0, view) if tool.respond_to?(:onCancel)
        ensure
          # Vendor cancellation is advisory. Always leave the tool and roll
          # back its unfinished operation, including when onCancel raises.
          model = Sketchup.active_model
          model.abort_operation while model.operation_depth > 0
          @active_tool_id = nil
          @failed_tool_id = nil
          view.reset_interaction
          # The snapshot can invalidate a private cursor face created after
          # start_operation. Discard it before sync; it is not an erased wall.
          view.set_cursor_data({})
          view.tooltip = ''
          Sketchup.status_text = ''
          model.tools.set_active(21022, 'SelectionTool')
          Bridge.notify('tool_select', 'id'=>nil, 'name'=>'Selection')
          Bridge.notify('tool_cancelled', 'tool'=>id)
        end
      when "reset"
        tool.onCancel(0, view) if tool.respond_to?(:onCancel)
        @active_tool_id=nil
        select_tool(tool)
      when "move"
        tool.onMouseMove(flags, x, y, view) if tool.respond_to?(:onMouseMove)
      when "click"
        tool.onLButtonDown(flags, x, y, view) if tool.respond_to?(:onLButtonDown)
      when "double_click"
        if tool.respond_to?(:onLButtonDoubleClick)
          tool.onLButtonDoubleClick(flags, x, y, view)
        elsif tool.respond_to?(:onLButtonDown)
          tool.onLButtonDown(flags, x, y, view)
        end
      when "release"
        tool.onLButtonUp(flags, x, y, view) if tool.respond_to?(:onLButtonUp)
      when "key"
        if msg['key'].to_i == 13 && tool.respond_to?(:onReturn)
          tool.onReturn(view)
        elsif tool.respond_to?(:onKeyDown)
            tool.onKeyDown(msg["key"].to_i, (msg['repeat'] || 1).to_i, flags, view)
        end
      when "key_up"
          tool.onKeyUp(msg["key"].to_i, (msg['repeat'] || 1).to_i, flags, view) if tool.respond_to?(:onKeyUp)
      when "value"
        tool.onUserText(msg['text'].to_s, view) if tool.respond_to?(:onUserText)
      end
      tool.onSetCursor if tool.respond_to?(:onSetCursor) && !%w[deactivate cancel].include?(msg['event'])
    rescue GenerationCancelled
      model=Sketchup.active_model
      model.abort_operation while model.operation_depth>0
      # The queued normal cancellation event runs the vendor's onCancel and
      # restores the selection tool after this callback returns.
    rescue StandardError, ScriptError => e
      @failed_tool_id = id unless %w[cancel deactivate].include?(msg['event'])
      Bridge.notify('tool_failed', 'id'=>id)
      Sketchup.log_exc("extension tool #{msg['event']}", e)
      Bridge.notify("error", "where" => "tool #{msg['event']}",
                             'tool'=>id,
                             "message" => "#{e.class}: #{e.message}",
                             "trace" => (e.backtrace || []).first(8))
    end

    def publish_overlay(view = Sketchup.active_model.active_view)
      tool = @tools[@active_tool_id] unless @failed_tool_id == @active_tool_id
      frame = tool.bridge_overlay_frame(view) if tool.respond_to?(:bridge_overlay_frame)
      view.begin_overlay_capture
      # Many original tools initialize their preview points on the first
      # mouse move. A draw before any cursor input must not fault the tool.
      tool.draw(view) if !frame && tool.respond_to?(:draw) && view.instance_variable_get(:@cursor)&.dig('valid')
      Sketchup.active_model.overlays.each do |overlay|
        overlay.draw(view) if overlay.valid? && overlay.enabled?
      end
      items = view.take_overlay
      message = {"items"=>items, 'tool'=>@active_tool_id}
      if @active_tool_id
        active = @tools[@active_tool_id]
        stage = active.instance_variable_get(:@stage) || active.instance_variable_get(:@state)
        message['tool_state'] = {'id'=>@active_tool_id, 'class'=>active.class.name,
          'title'=>@command_title, 'stage'=>stage.is_a?(Numeric) ? stage : nil,
          'hint'=>view.tooltip.to_s.empty? ? Sketchup.status_text : view.tooltip,
          'normal'=>view.instance_variable_get(:@cursor)&.dig('normal'),
          'failed'=>@failed_tool_id == @active_tool_id}
      end
        message['interaction'] = {'tool'=>@active_tool_id,'state'=>view.interaction_state}
        if tool.respond_to?(:bridge_inference_state)
          message['inference'] = {'tool'=>@active_tool_id, 'state'=>tool.bridge_inference_state}
          items.concat(tool.bridge_inference_items)
        end
      if frame
        instance = {"mode"=>"instance","template"=>frame[:key]}
        instance['origin'] = frame[:origin] if frame[:origin]
        instance['matrix'] = frame[:matrix] if frame[:matrix]
        instance['color'] = frame[:color] if frame[:color]
        items.unshift(instance)
        items.concat(frame[:extra] || [])
        if @sent_overlay_template != frame[:key]
          message['templates'] = {frame[:key]=>frame[:items]}
          @sent_overlay_template = frame[:key]
        end
      else
        @sent_overlay_template = nil
      end
      Bridge.notify("overlay",message)
      @last_preview_error = nil
    rescue StandardError => e
      # A preview can lack its next point between two clicks. Keep routing
      # input so the next move/click can recover; only callback failures fault
      # a tool. Escape still works in either state.
      signature=[@active_tool_id,e.class.name,e.message]
      Sketchup.log_exc("extension overlay", e) unless signature==@last_preview_error
      @last_preview_error=signature
      Bridge.notify("overlay", "items" => [], 'tool'=>@active_tool_id, 'preview_error'=>true)
    end

    # Selection from IngeTrazo. Items:
    #   {"kind":"bogdan","rid":n|nil,"uid":..,"attrs":{..},"xform":[16],"name":..}
    #   {"kind":"face","token":..,"outer":[[x,y,z]...],"holes":[...],"normal":[..]}
    #   {"kind":"group","uid":..,"faces":[{"outer":..,"holes":..}],"xform":[16]|nil}
    def set_selection(items, camera_dir)
      model = Sketchup.active_model
      @native_definition_cache={}
      @native_surface_materials={}
      if camera_dir && !model.active_view.native_camera?
        cam = model.active_view.camera
        d = Geom::Vector3d.new(camera_dir)
        cam.set(Geom::Point3d.new(0, 0, 0) - d * 1000.0, Geom::Point3d.new(0, 0, 0), Z_AXIS)
      end
      # Forget the previous host-face proxies.
      imported_faces=(model.entities.faces.select { |face| face.instance_variable_get(:@adapter_surface_token) }+
        @host_faces.values.map { |h| h[:face] }).uniq
      imported_edges=imported_faces.flat_map(&:edges)
      imported_faces.each { |face| model.entities.erase_face_only(face) if face.valid? }
      imported_edges.each { |edge| edge.erase! if edge.valid? && edge.faces.empty? }
      @host_faces.clear
      @cursor_surface_records={}
      @host_surface_edges=[]
      @host_edges.each { |edge| edge.erase! if edge.valid? && edge.faces.empty? }
      @host_edges.clear
      @host_edge_records={}
      @proxy_groups ||= []
      # Native group proxies represent model entities, not the selection
      # itself. Keep them across selection refreshes so observers and plugin
      # caches do not retain invalid objects merely because the user selected
      # something else. Native history notifications reconcile removals.
      @proxy_groups.select!(&:valid?)
      sel = []
      # Faces first so selected boundary lines reuse the corresponding edges.
      items.sort_by { |it| it["kind"] == "edge" ? 1 : 0 }.each do |it|
        case it["kind"]
        when "wc", "bogdan"
          ent = it["rid"] && @rid_map[it["rid"]]
          ent = nil if ent && !ent.valid?
          if ent && it['geometry']
            @native_snapshot_digests ||= {}
            uid = it['uid'].to_s
            digest = Digest::SHA1.hexdigest(JSON.generate(it['geometry']))
            if @native_snapshot_digests.key?(uid) && @native_snapshot_digests[uid] != digest
              temporary = build_pick_entity(it['geometry'], Sketchup::Entities.new(model), 0)
              ent.definition = temporary.definition
              temporary.erase!
              @native_snapshot_digests[uid] = digest
            end
            @native_snapshot_digests[uid] = digest
          end
          ent ||= stub_container(it)
          ent.transformation = xform_in(it["xform"]) if it["xform"]
          ent.hidden = !!it["hidden"] if ent.respond_to?(:hidden=)
          @sent_digest[ent.entityID] = Digest::SHA1.hexdigest(JSON.generate(export_container(ent)))
          @uid_to_rid ||= {}
          @uid_to_rid[it["uid"].to_s] = ent.entityID if it["uid"]
          Bridge.notify("bind", "uid" => it["uid"], "rid" => ent.entityID)
          sel << ent
        when "face"
          pts = it["outer"].map { |p| Geom::Point3d.new(p[0] / INCH, p[1] / INCH, p[2] / INCH) }
          f = model.entities.add_face_raw(pts)
          next unless f
          (it["holes"] || []).each { |h| f.add_hole(h.map { |p| model.entities.vertex(Geom::Point3d.new(p[0] / INCH, p[1] / INCH, p[2] / INCH)) }) }
          if it["normal"] && f.normal.dot(Geom::Vector3d.new(it["normal"])) < 0
            f.reverse!
          end
          f.instance_variable_set(:@adapter_surface_token,it['token'])
          f.edges.each { |edge| edge.instance_variable_set(:@adapter_surface_edge,true) }
          import_surface_edge_properties(f,it['edge_properties'])
          f.layer=it['layer'] if it['layer']
          if it['attrs'].is_a?(Hash)
            f.set_attribute('_ingetrazo_bridge', 'face_attrs', it['attrs'])
            restore_face_materials(f, it['proxy_attrs'] || it['attrs'], method(:restore_surface_material))
          end
          @host_faces[f.entityID] = { face: f, token: it["token"],baseline:JSON.generate(native_surface_faces([f])) }
          @host_surface_edges.concat(f.edges)
          sel << f unless it['_context_only']
        when "edge"
          import_native_edges([it])
          edge=native_edge(it['token'])
          sel << edge if edge && !it['_context_only']
        when "group"
          @proxy_entities ||= model.entities
          snapshot = it["geometry"] || { "name" => "", "component" => false,
                                          "xform" => it["xform"], "faces" => [], "children" => [] }
          snapshot = snapshot.dup
          snapshot["xform"] = it["xform"] if it["xform"]
          uid = it['uid'].to_s
          rid = (@uid_to_rid || {})[uid]
          g = rid && @proxy_rids[rid] && @rid_map[rid]
          if g && g.valid? && (g.is_a?(Sketchup::ComponentInstance) != !!snapshot['component'])
            g.erase!
            @proxy_groups.delete(g); @proxy_rids.delete(rid); @proxy_group_uids.delete(rid)
            @rid_map.delete(rid); @sent_digest.delete(rid); @uid_to_rid.delete(uid)
            g = nil
          end
          g = nil unless g && g.valid?
          if g
            digest=Digest::SHA1.hexdigest(JSON.generate(snapshot))
            @native_snapshot_digests ||= {}
            if @native_snapshot_digests[uid] != digest
              temporary=build_pick_entity(snapshot, Sketchup::Entities.new(model), 0)
              g.definition=temporary.definition
              temporary.erase!
              @native_snapshot_digests[uid]=digest
            end
            g.transformation=snapshot['xform'] ? xform_in(snapshot['xform']) : Geom::Transformation.new
            g.hidden=!!snapshot['hidden']
            g.name=snapshot['name'].to_s if snapshot['name']
            g.layer=snapshot['layer']
          else
            g = build_pick_entity(snapshot, @proxy_entities, 0)
            @native_snapshot_digests ||= {}
            @native_snapshot_digests[uid]=Digest::SHA1.hexdigest(JSON.generate(snapshot)) if g
          end
          next unless g
          g.instance_variable_set(:@bridge_copy_parent,model.entities)
          @proxy_groups << g unless @proxy_groups.include?(g)
          @proxy_rids[g.entityID] = true
          @proxy_group_uids[g.entityID] = it["uid"].to_s if it["uid"]
          @rid_map[g.entityID] = g
          @sent_digest[g.entityID] = Digest::SHA1.hexdigest(JSON.generate(export_container(g)))
          if it["uid"]
            @uid_to_rid ||= {}
            @uid_to_rid[it["uid"].to_s] = g.entityID
            Bridge.notify("bind", "uid" => it["uid"], "rid" => g.entityID)
            deliver_native_added(it["uid"],g)
          end
          sel << g
        end
      end
      model.selection.set_silently([])
      model.selection.add(sel)
      model.selection.notify(:onSelectionCleared) if sel.empty?
    end

    # An item placed in an earlier session: rebuild the Ruby container from
    # the attribute dictionaries IngeTrazo stored with it.
    def stub_container(it)
      model = Sketchup.active_model
      snap = (it["geometry"] || {}).dup
      snap["uid"] = it["uid"]
      snap["name"] = it["inst_name"].to_s.empty? ? it["name"].to_s : it["inst_name"].to_s
      snap["component"] = true unless snap.key?("component")
      snap["xform"] = it["xform"] || snap["xform"]
      snap["attrs"] = it["attrs"] || snap["attrs"] || {}
      snap["def_attrs"] = it["def_attrs"] || snap["def_attrs"] || {}
      inst = build_pick_entity(snap, model.entities, 0)
      raise "Could not rebuild selected extension object" unless inst
      inst
    end

    def placed(def_id, xform)
      defn = @pending.delete(def_id)
      return unless defn
      model = Sketchup.active_model
      inst = model.entities.add_instance(defn, xform_in(xform))
      rid = inst.entityID
      @rid_map[rid] = inst
      @sent_digest[rid] = Digest::SHA1.hexdigest(JSON.generate(export_container(inst)))
      model.tools.set_active(21013, "ComponentTool")
      model.tools.set_active(21022, "SelectionTool")
      rid
    end

    def cancelled(def_id)
      @pending.delete(def_id)
      model = Sketchup.active_model
      model.tools.set_active(21013, "ComponentTool")
      model.tools.set_active(21022, "SelectionTool")
    end

    def context_menu
      menu = UI::Menu.new("Context", context: true)
      UI.with_context_menu do
        UI.context_handlers.each do |h|
          begin
            h.call(menu)
          rescue StandardError => e
            Sketchup.log_exc("context menu", e)
          end
        end
      end
      menu.to_h
    end

    def dispatch(msg)
      initial_operation_depth=Sketchup.active_model.operation_depth
      extension_aborted=false
      case msg["op"]
      when "command"
        cmd = UI.command(msg["id"])
        @command_title = cmd.menu_text.to_s.strip if cmd
        cmd.run if cmd
      when "callback"
        dlg = UI::HtmlDialog.all[msg["dialog"].to_i]
        cb = dlg && dlg.callbacks[msg["name"].to_s]
        if cb
          dlg.remember_values(msg['values']) if dlg.respond_to?(:remember_values) && msg['values']
          cb.call(dlg.is_a?(UI::WebDialog) ? dlg : UI::ActionContext.new, *(msg["args"] || []))
        else
          $stderr.puts "SketchUp adapter host: no callback #{msg['name']}"
        end
      when "dialog_closed"
        dlg = UI::HtmlDialog.all[msg["dialog"].to_i]
        dlg.mark_closed! if dlg
      when "dialog_resized"
        dlg = UI::HtmlDialog.all[msg["dialog"].to_i]
        dlg.remember_size(msg["w"], msg["h"]) if dlg
      when "dialog_moved"
        dlg = UI::HtmlDialog.all[msg["dialog"].to_i]
        dlg.remember_position(msg["x"], msg["y"]) if dlg
      when "dialog_close_requested"
        dlg = UI::HtmlDialog.all[msg["dialog"].to_i]
        dlg.close if dlg
      when "selection"
        set_selection(msg["items"] || [], msg["camera"])
      when "model_state"
        native_model_state(msg)
      when 'native_binding'
        @uid_to_rid ||= {}
        @uid_to_rid[msg['uid'].to_s]=msg['rid'].to_i
      when "placed"
        rid = placed(msg["def"].to_i, msg["xform"])
        if rid && msg["uid"]
          @uid_to_rid ||= {}
          @uid_to_rid[msg["uid"].to_s] = rid
          Bridge.notify("bind", "uid" => msg["uid"], "rid" => rid)
        end
      when "place_cancelled"
        cancelled(msg["def"].to_i)
      when "tool_event"
        dispatch_tool_event(msg)
      when "moved"
        ent = @rid_map[msg["rid"].to_i]
        if ent && ent.valid?
          ent.transformation = xform_in(msg["xform"])
          @sent_digest[ent.entityID] = Digest::SHA1.hexdigest(JSON.generate(export_container(ent)))
        end
      when "erased"
        (msg["rids"] || []).each do |rid|
          ent = @rid_map.delete(rid.to_i)
          @sent_digest.delete(rid.to_i)
          Sketchup.active_model.entities.erase_entities(ent) if ent && ent.valid?
        end
      when "context_menu"
        Bridge.notify("context_menu", "menu" => context_menu, "req" => msg["req"])
      when "menu_click"
        cmd = UI.command(msg["id"])
        @command_title = cmd.menu_text.to_s.strip if cmd
        cmd.run if cmd
      when "units"
        o = Sketchup.active_model.options["UnitsOptions"]
        o.change("LengthPrecision", msg["precision"].to_i) if msg["precision"]
        o.change("LengthUnit", msg["unit"].to_i)
      when "rendering_options"
        Sketchup.active_model.rendering_options.apply_native_snapshot(msg['values'])
      when "native_camera"
        Sketchup.active_model.active_view.apply_native_camera(msg['values'])
      when "ping"
        Bridge.notify("pong")
      when "document_reset"
        reset_document
      when "quit"
        exit(0)
      end
    rescue SystemExit => e
      # An extension may use abort/exit inside a callback. Stop that callback,
      # but keep the worker alive so the native host can discard its uncommitted
      # proxy state and report the failure. Never intercept normal host quit or
      # extension loading, and never continue the aborted callback.
      raise unless %w[command callback menu_click tool_event].include?(msg['op'])
      extension_aborted=true
      begin
        model=Sketchup.active_model
        model.abort_operation while model.operation_depth>0
      rescue StandardError => rollback_error
        Sketchup.log_exc('extension abort rollback', rollback_error)
      end
      Bridge.notify('extension_abort', 'where'=>msg['op'].to_s, 'status'=>e.status.to_i)
    rescue StandardError, ScriptError => e
      if %w[command callback menu_click].include?(msg['op'])
        model=Sketchup.active_model
        model.abort_operation while model.operation_depth>initial_operation_depth
      end
      Sketchup.log_exc("dispatch #{msg['op']}", e)
      Bridge.notify("error", "where" => msg["op"].to_s, "message" => "#{e.class}: #{e.message}",
                             "trace" => (e.backtrace || []).first(8))
    ensure
      unless msg['op'] == 'quit' || extension_aborted
        begin
          sync
        rescue StandardError => e
          Sketchup.log_exc("sync", e)
        end
        begin
          publish_overlay
        rescue StandardError => e
          Sketchup.log_exc("overlay publish", e)
        end
        if %w[command callback tool_event menu_click].include?(msg['op']) && Sketchup.active_model.operation_depth.zero?
          Bridge.notify('activity_done')
        end
      end
    end

    def load_plugins(plugins_dir, loaders)
      Sketchup.plugins_dir = plugins_dir
      $LOAD_PATH.unshift(plugins_dir)
      loaded = 0
      Array(loaders).each do |loader|
        begin
          require File.join(plugins_dir, loader.to_s)
          loaded += 1
        rescue StandardError, ScriptError => e
          Sketchup.log_exc("load #{loader}", e)
          Bridge.notify("extension_error", "loader" => loader.to_s,
                         "message" => "#{e.class}: #{e.message}",
                         "trace" => (e.backtrace || []).first(8))
        end
      end
      install_ingetrazo_overrides
        raise "No SketchUp extensions could be loaded" if loaded.zero?
      menu = UI.menu("Extensions")
      Bridge.notify("ready", "commands" => UI.commands.map(&:to_h), "menu" => menu.to_h,
                             "version" => "SketchUp extensions", "build" => 0,
                             "loaded" => loaded)
    end

    def run(plugins_dir, loaders)
      begin
        load_plugins(plugins_dir, loaders)
      rescue StandardError, ScriptError => e
        Sketchup.log_exc("load", e)
        Bridge.notify("fatal", "message" => "#{e.class}: #{e.message}", "trace" => (e.backtrace || []).first(12))
        exit(1)
      end
      loop do
        until Bridge.queue.empty?
          dispatch(Bridge.queue.shift)
        end
        UI.run_due_timers
        delay = UI.next_timer_delay
        ready = IO.select([$stdin], nil, nil, delay)
        if ready
          line = $stdin.gets
          break if line.nil?
          msg = (JSON.parse(line) rescue nil)
          dispatch(msg) if msg
        elsif !UI.timers.empty?
          before = Host.digest_all
          UI.run_due_timers
          sync if before != Host.digest_all
        end
      end
    end

    def digest_all
      model = Sketchup.active_model
      [model.entities.length, model.committed_revision]
    end
  end
end

require_relative 'native_lifecycle'
require_relative 'universal'
require_relative 'native_surfaces'
require_relative 'native_edges'
require_relative 'native_selection'
require_relative 'native_context'
require_relative 'native_guides'
if $PROGRAM_NAME == __FILE__
  loaders = ARGV[1] ? JSON.parse(ARGV[1].start_with?('@') ? File.read(ARGV[1][1..-1],encoding:'UTF-8') : ARGV[1]) : []
  Host.run(ARGV[0], loaders)
end
