# SPDX-License-Identifier: GPL-3.0-or-later
# Legacy RBS1.0 record reader. This handles the container only: it does not
# alter activation, licensing, entitlement checks or the loaded Ruby program.
require 'fiddle'
require 'rbconfig'

module SketchupAdapter
  module RBS
    HEADER='RBS1.0'.b.freeze
    MAX_RECORD=16*1024*1024

    class << self
      def crypto_library
        @crypto_library ||= begin
          candidates=[ENV['SKETCHUP_ADAPTER_LIBCRYPTO'],
            File.join(RbConfig::CONFIG['bindir'],'ruby_builtin_dlls','libcrypto-3-x64.dll'),
            File.join(RbConfig::CONFIG['bindir'],'libcrypto-3-x64.dll'),
            'libcrypto.so.3','libcrypto.dylib'].compact
          handle=nil
          candidates.each do |path|
            begin
              handle=Fiddle.dlopen(path)
              handle['BF_set_key'];handle['BF_decrypt']
              break
            rescue Fiddle::DLError
              handle=nil
            end
          end
          raise LoadError,'Legacy RBS loading needs an OpenSSL library exporting BF_set_key and BF_decrypt' unless handle
          handle
        end
      end

      def key_schedule(password)
        raise ArgumentError,'Invalid legacy RBS format key length' unless (1..56).cover?(password.bytesize)
        schedule=Fiddle::Pointer.malloc((18+1024)*4,Fiddle::RUBY_FREE)
        function=Fiddle::Function.new(crypto_library['BF_set_key'],
          [Fiddle::TYPE_VOIDP,Fiddle::TYPE_INT,Fiddle::TYPE_VOIDP],Fiddle::TYPE_VOID)
        function.call(schedule,password.bytesize,password)
        schedule
      end

      def decode(path,password)
        raise LoadError,'RBS1.0 is currently supported on little-endian platforms only' unless [1].pack('I')==[1,0,0,0].pack('C*')
        schedule=key_schedule(password.b)
        decrypt=Fiddle::Function.new(crypto_library['BF_decrypt'],
          [Fiddle::TYPE_VOIDP,Fiddle::TYPE_VOIDP],Fiddle::TYPE_VOID)
        source=String.new(encoding:Encoding::BINARY)
        File.open(path,'rb') do |input|
          raise LoadError,'Not a legacy RBS1.0 container' unless input.read(6)==HEADER
          until input.eof?
            size_bytes=input.read(4)
            raise LoadError,'Truncated RBS record header' unless size_bytes && size_bytes.bytesize==4
            size=size_bytes.unpack1('V')
            raise LoadError,'Invalid RBS record size' if size>MAX_RECORD || size%8!=0
            record=input.read(size)
            raise LoadError,'Truncated RBS record' unless record && record.bytesize==size
            # OpenSSL writes in place. Use owned native storage instead of
            # a pointer into Ruby String storage (short records may embed
            # their bytes in a GC-managed object).
            buffer=Fiddle::Pointer.malloc([size,1].max,Fiddle::RUBY_FREE)
            buffer[0,size]=record if size>0
            (size/8).times { |index| decrypt.call(buffer+index*8,schedule) }
            source << buffer[0,size].sub(/\x00+\z/n,'')
          end
        end
        source
      end

      def source(path)
        keyfile=ENV['SKETCHUP_ADAPTER_RBS_KEY_FILE']
        keyfile ||= File.join(SketchupAdapter.data_root.to_s,'rbs-format-key.bin') if SketchupAdapter.respond_to?(:data_root) && SketchupAdapter.data_root
        raise LoadError,'Legacy RBS format key is not configured' unless keyfile && File.file?(keyfile)
        text=decode(path,File.binread(keyfile))
        # Use the original filename so resource lookups and backtraces remain
        # correct. Validate before evaluating even when the data decrypts.
        encoding=text[/coding\s*[:=]\s*([\w-]+)/n,1]
        text.force_encoding(encoding || Encoding::UTF_8)
        raise LoadError,'Decoded RBS source has an invalid text encoding' unless text.valid_encoding?
        RubyVM::InstructionSequence.compile(text,path,path,1) if defined?(RubyVM::InstructionSequence)
        text
      end

      def load(path)
        Kernel.eval(source(path),TOPLEVEL_BINDING,path,1)
        true
      end

      def require(path)
        path=File.expand_path(path)
        return false if $LOADED_FEATURES.include?(path)
        (@loading ||= {})[path] && (return false)
        @loading[path]=true
        begin
          load(path)
          $LOADED_FEATURES << path
          true
        ensure
          @loading.delete(path)
        end
      end
    end
  end
end
