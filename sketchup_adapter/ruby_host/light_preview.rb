# Cache hanging-lamp preview geometry in local inches. Moving the mouse sends
# only a new origin; it never reduces the built lamp's geometry or detail.
module Host
  module SurfacePreview
    def refresh_plan
      key = JSON.generate([@entry['id'], settings])
      return if @bridge_surface_key == key && @plan && @local_lines
      super
      @bridge_surface_key = key
      @bridge_surface_items = nil
    end

    def rebuild_world
      @world_lines = []
      return unless @target && @point && @local_lines
      @allowed = surface_ok?(@target[:normal])
    end

    def bridge_overlay_frame(_view)
      return nil unless @target && @point && @local_lines
      @bridge_surface_items ||= @local_lines.map do |line|
        {'mode'=>'line_strip','space'=>'world','color'=>self.class::OK.to_a,
         'width'=>1,'stipple'=>'','points'=>line.map { |p| p.map { |v| v*self.class::CM } }}
      end
      color = (@allowed ? self.class::OK : self.class::BAD).to_a
      {key:"surface-#{object_id}-#{Digest::SHA1.hexdigest(@bridge_surface_key)}",
       matrix:frame.to_a, color:color, items:@bridge_surface_items,
       extra:[{'mode'=>'points','space'=>'world','points'=>[@point.to_a],'point_size'=>10,'color'=>color},
              {'mode'=>'text','space'=>'world','points'=>[@point.to_a],'text'=>label,'color'=>color}]}
    end
  end

  module HangingPreview
    def rebuild_plan
      base = @base || @hover
      return unless base && @ceiling_z
      ceiling = @auto_ceiling && @base.nil? ? @auto_ceiling : @ceiling_z
      rel = (ceiling - base.z) / self.class::CM
      key = JSON.generate([lamp_settings, rel])
      return if @bridge_preview_key == key && @plan && @draw
      @plan = build_plan(rel)
      @draw = wire_data(Geom::Point3d.new(0,0,0), @plan)
      @bridge_preview_key = key
      @bridge_preview_items = nil
    end

    def bridge_overlay_frame(view)
      base = @base || @hover
      return nil unless base && @plan && @draw
      unless @bridge_preview_items
        saved_base, saved_hover = @base, @hover
        begin
          @base = Geom::Point3d.new(0,0,0) if @base
          @hover = Geom::Point3d.new(0,0,0) if @hover
          view.begin_overlay_capture
          draw(view)
          @bridge_preview_items = view.take_overlay
        ensure
          @base, @hover = saved_base, saved_hover
        end
      end
      {key: "hang-#{object_id}-#{Digest::SHA1.hexdigest(@bridge_preview_key)}",
       origin: base.to_a, items: @bridge_preview_items}
    end

    def draw_label(view, base)
      point = world(base, [0,0,@plan['shade_bottom']/2.0])
      label = if @plan['valid']
        format('Drop %.0f cm  |  Cord %.0f cm', @plan['drop'], @plan['cord_length'])
      else
        format('Ceiling too close: cord %.0f cm, needs %.0f cm', @plan['cord_length'], BogdanLightCrafter::ShadePlan::MIN_CORD)
      end
      # A world-space label follows camera changes without a worker round trip.
      view.draw_text(point,label,size:12,bold:true)
    end
  end
end
