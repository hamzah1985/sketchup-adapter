# Native face proxies form a connected drawing context. Changes are returned
# to their original surfaces; imported context is never published as new mesh.
module Host
  class << self
    def import_surface_edge_properties(face,records)
      Array(records).each do |data|
        points=data['points'].map { |p| Geom::Point3d.new(p.map { |v| v/INCH }) }
        edge=face.edges.find { |e| (e.start.position==points[0] && e.end.position==points[1]) || (e.end.position==points[0] && e.start.position==points[1]) }
        next unless edge
        edge.soft=!!data['soft'];edge.hidden=!!data['hidden'];edge.smooth=!!data['smooth']
        edge.casts_shadows=data.fetch('casts_shadows',true)
        token=data['token']
        if token
          @host_edge_records ||= {}
          reversed=edge.start.position.distance(points[0])>1e-7
          source={'kind'=>'edge','token'=>token,'a'=>data['points'][0],'b'=>data['points'][1],
                  'soft'=>!!data['soft'],'hidden'=>!!data['hidden'],'layer'=>edge.layer.name}
          @host_edge_records[token]={edge:edge,source:source,reversed:reversed,
            baseline:native_edge_data(edge,reversed),surface_boundary:true}
          edge.instance_variable_set(:@adapter_edge_token,token)
          @host_edges << edge unless @host_edges.include?(edge)
        end
      end
    end
    def import_cursor_context(records)
      model=Sketchup.active_model
      known=@host_faces.values.to_h { |record| [record[:token],record] }
      Array(records).each do |data|
        next unless data['kind']=='face'
        next if known[data['token']] && known[data['token']][:face].valid?
        face=model.entities.add_face_raw(data['outer'].map { |p| Geom::Point3d.new(p.map { |v| v/INCH }) })
        next unless face
        Array(data['holes']).each do |ring|
          face.add_hole(ring.map { |p| model.entities.vertex(Geom::Point3d.new(p.map { |v| v/INCH })) })
        end
        face.reverse! if data['normal'] && face.normal.dot(Geom::Vector3d.new(data['normal']))<0
        face.instance_variable_set(:@adapter_surface_token,data['token'])
        face.edges.each { |edge| edge.instance_variable_set(:@adapter_surface_edge,true) }
        import_surface_edge_properties(face,data['edge_properties'])
        if data['attrs'].is_a?(Hash)
          face.set_attribute('_ingetrazo_bridge','face_attrs',data['attrs'])
          restore_face_materials(face,data['proxy_attrs'] || data['attrs'],method(:restore_surface_material))
        end
        record={face:face,token:data['token'],baseline:JSON.generate(native_surface_faces([face]))}
        @host_faces[face.entityID]=record
        (@cursor_surface_records ||= {})[data['token']]=data
        known[data['token']]=record
        @host_surface_edges ||= []
        @host_surface_edges.concat(face.edges)
      end
    end

    def restore_cursor_context
      # A tool may open its operation before the first mouse move imports
      # a wall. Aborting that snapshot discards the later read-only proxies;
      # rebuild them instead of reporting their absence as a native deletion.
      missing=@host_faces.values.select { |record| !record[:face].valid? && (@cursor_surface_records || {}).key?(record[:token]) }
      records=missing.map { |record| @cursor_surface_records[record[:token]] }
      missing.each { |record| @host_faces.delete(record[:face].entityID) }
      Sketchup.silence_bridge_events { import_cursor_context(records) } unless records.empty?
    end

    def native_surface_faces(faces)
      definition=Sketchup::ComponentDefinition.new('Native surface export')
      definition.entities.instance_variable_set(:@items,faces)
      result=export_definition(definition)['protos'][0]['faces']
      result.zip(faces).each do |data,face|
        edits = {}
        [true, false].each do |front|
          side = front ? 'front' : 'back'
          baseline = face.instance_variable_get(front ? :@adapter_paint_baseline_front : :@adapter_paint_baseline_back)
          dirty = face.instance_variable_get(front ? :@adapter_paint_dirty_front : :@adapter_paint_dirty_back)
          issued = face.instance_variable_get(front ? :@adapter_paint_issued_front : :@adapter_paint_issued_back)
          current = face_side_stamp(face, front)
          # Compare with the last issued value after the first edit. Returning
          # to the original is still a change, while an unchanged side must
          # not overwrite independent native edits on a later geometry patch.
          next unless issued ? current != issued : (baseline ? current != baseline : dirty)
          material = front ? face.material : face.back_material
          paint = material_attrs(material, {})
          preserve = false
          original = face.get_attribute('_ingetrazo_bridge','face_attrs',{})
          old_side = front ? original : original['back']
          old_tex = old_side.is_a?(Hash) ? old_side['texture'] : nil
          old_material = face.instance_variable_get(front ? :@adapter_original_material_front : :@adapter_original_material_back)
          # If the original texture file was unavailable, it could not be
          # reconstructed on the Ruby proxy. Do not silently drop it when an
          # extension changes that same material object; force preflight to
          # reject the batch. Assigning a different material or nil is explicit.
          if old_tex.is_a?(Hash) && material && material.equal?(old_material) && !material.texture
            paint['texture'] = {'path'=>old_tex['path']}
          end
          if paint && paint['texture']
            map = front ? face.uv_mapping : face.uv_mapping_back
            old_map = face.instance_variable_get(front ? :@adapter_paint_mapping_front : :@adapter_paint_mapping_back)
            preserve = !issued && old_tex.is_a?(Hash) && %w[path sw sh].all? { |key| old_tex[key] == paint['texture'][key] } &&
                       (map && map.map(&:to_a)) == old_map
            unless preserve || (old_tex.is_a?(Hash) && material.equal?(old_material) && !material.texture)
              uvw = face_uvw(face, face.outer_loop.points, front)
              paint['texture'] = paint['texture'].merge('uvw'=>uvw) if uvw
            end
          end
          edits[side] = {'value'=>paint, 'preserve_uvw'=>preserve}
        end
        data[2]['_adapter_paint_edits'] = edits unless edits.empty?
        data[2]['_sketchup_edge_properties']=face.edges.map { |edge| {'points'=>edge.vertices.map { |v| m(v.position) },
          'soft'=>edge.soft?,'hidden'=>edge.hidden?,'smooth'=>edge.smooth?,'casts_shadows'=>edge.casts_shadows?} }
      end
      result
    end

    def sync_native_surfaces
      grouped=Sketchup.active_model.entities.faces.group_by { |face| face.instance_variable_get(:@adapter_surface_token) }
      (@host_faces || {}).each_value do |record|
        next unless record.key?(:baseline)
        faces=native_surface_faces(grouped[record[:token]] || [])
        stamp=JSON.generate(faces)
        next if stamp==record[:baseline]
        record[:baseline]=stamp
        proxy_faces=grouped[record[:token]] || []
        # Only a single surviving *same* Ruby object can retain this token.
        # Splits and replacement proxies need a distinct identity protocol.
        identity_preserved=proxy_faces.length==1 && proxy_faces[0].equal?(record[:face]) && record[:face].valid?
        Bridge.notify('surface_patch','token'=>record[:token],'faces'=>faces,
                      'identity_preserved'=>identity_preserved)
        if identity_preserved
          edits=faces[0][2]['_adapter_paint_edits'] || {}
          edits.each_key do |side|
            proxy_faces[0].instance_variable_set(side=='front' ? :@adapter_paint_issued_front : :@adapter_paint_issued_back,
                                                 face_side_stamp(proxy_faces[0],side=='front'))
          end
          record[:baseline]=JSON.generate(native_surface_faces(proxy_faces)) unless edits.empty?
        end
      end
    end
  end
end
