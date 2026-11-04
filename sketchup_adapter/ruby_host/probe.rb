# SPDX-License-Identifier: GPL-3.0-or-later
# Startup-only compatibility probe, in a disposable Ruby process. It does not
# connect to a running IngeTrazo document or execute toolbar commands.
require_relative 'host'
module Bridge
  class << self
    def call(function, data={})
      notify('probe_prompt', 'function'=>function, 'title'=>data['title'])
      function == 'messagebox' ? IDCANCEL : nil
    end
  end
end
config=JSON.parse(File.read(ARGV.fetch(0),encoding:'UTF-8'))
Host.load_plugins(config['data_root'] || Dir.pwd,config)
Bridge.notify('probe_report', 'plugins'=>SketchupAdapter.results,
              'commands'=>UI.commands.map(&:to_h), 'api_gaps'=>SketchupAdapter.gaps.size,
              'startup_only'=>true, 'workflow_compatibility'=>'unverified')
