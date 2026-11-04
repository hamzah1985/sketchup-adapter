# SPDX-License-Identifier: GPL-3.0-or-later
# Small source plugin for testing the adapter's public SketchUp API surface.
require 'sketchup.rb'
module SketchupAdapterLab
  def self.cube
    model=Sketchup.active_model
    model.start_operation('Adapter cube',true)
    group=model.active_entities.add_group
    group.name='Adapter cube (1 metre)'
    face=group.entities.add_face([0,0,0],[1.m,0,0],[1.m,1.m,0],[0,1.m,0])
    face.reverse! if face.normal.z<0
    face.pushpull(1.m)
    model.commit_operation
    group
  rescue Exception
    model.abort_operation
    raise
  end
  def self.surface
    model=Sketchup.active_model
    model.start_operation('Adapter surface',true)
    model.active_entities.build { |builder|
      builder.add_face([[0,0,0],[2.m,0,0],[2.m,2.m,0],[0,2.m,0]],
        holes:[[[0.5.m,0.5.m,0],[0.5.m,1.5.m,0],[1.5.m,1.5.m,0],[1.5.m,0.5.m,0]]])
    }
    model.commit_operation
  rescue Exception
    model.abort_operation
    raise
  end
  unless file_loaded?(__FILE__)
    cube=UI::Command.new('Create Adapter Test Cube') { cube() }
    surface=UI::Command.new('Create Adapter Test Surface') { surface() }
    cube.tooltip='Create a one metre cube using the SketchUp Ruby API.'
    toolbar=UI::Toolbar.new('SketchUp Adapter Lab')
    toolbar.add_item(cube)
    toolbar.add_item(surface)
    toolbar.show
    menu=UI.menu('Extensions').add_submenu('Adapter Lab')
    menu.add_item(cube)
    menu.add_item(surface)
    file_loaded(__FILE__)
  end
end
