require 'tmpdir'
require 'json'
require_relative '../sketchup_adapter/ruby_host/rbs'
checks=[]
Dir.mktmpdir('rbs-container-test-') do |root|
  path=File.join(root,'test.rbs')
  # Published Blowfish known-answer vector: zero key, zero plaintext ->
  # 4EF997456198DD78. RBS stores the two 32-bit words little-endian.
  File.binwrite(path,'RBS1.0'+[8].pack('V')+['4597f94e78dd9861'].pack('H*'))
  raise 'Known-answer decrypt failed' unless SketchupAdapter::RBS.decode(path,"\0"*8)==''
  checks << 'Blowfish known-answer vector / RBS word order'

  password='independent container test'
  schedule=SketchupAdapter::RBS.key_schedule(password)
  encrypt=Fiddle::Function.new(SketchupAdapter::RBS.crypto_library['BF_encrypt'],
    [Fiddle::TYPE_VOIDP,Fiddle::TYPE_VOIDP],Fiddle::TYPE_VOID)
  records=["puts 'first record'\n","puts 'second record'\n"]
  content=records.map do |record|
    data=record.b.ljust((record.bytesize+7)/8*8,"\0")
    pointer=Fiddle::Pointer[data]
    (data.bytesize/8).times { |index| encrypt.call(pointer+index*8,schedule) }
    [data.bytesize].pack('V')+data
  end.join
  File.binwrite(path,'RBS1.0'+content)
  raise 'Multiple records failed' unless SketchupAdapter::RBS.decode(path,password)==records.join
  checks << 'Independent records / padding / concatenation'

  ['BADHDR',[9].pack('V')+'123456789',[16].pack('V')+'short'].each do |payload|
    File.binwrite(path,payload=='BADHDR' ? payload : 'RBS1.0'+payload)
    begin
      SketchupAdapter::RBS.decode(path,password)
      raise 'Malformed container accepted'
    rescue LoadError
    end
  end
  checks << 'Malformed header / block size / truncated data rejected'
end
puts JSON.pretty_generate({'status'=>'PASS','checks'=>checks,'sketchup_executed'=>false})
