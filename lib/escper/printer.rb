module Escper
  class Printer
    # mode can be local or sass
    # vendor_printers can either be a single VendorPrinter object, or an Array of VendorPrinter objects, or an ActiveRecord Relation containing VendorPrinter objects.
    def initialize(mode='local', vendor_printers=nil, subdomain=nil)
      @mode = mode
      @subdomain = subdomain
      @open_printers = Hash.new
      @codepages_lookup = YAML::load(File.read(Escper.codepage_file))
      @file_mode = 'wb'
      if defined?(Rails)
        @fallback_root_path = Rails.root
      else
        @fallback_root_path = '/'
      end
      if vendor_printers.kind_of?(Array) or (defined?(ActiveRecord) == 'constant' and vendor_printers.kind_of?(ActiveRecord::Relation))
        @vendor_printers = vendor_printers
      elsif vendor_printers.kind_of?(VendorPrinter) or vendor_printers.kind_of?(::VendorPrinter)
        @vendor_printers = [vendor_printers]
      else
        # If no available VendorPrinters are initialized, create a set of temporary VendorPrinters with usual device paths.
        Escper.log "No VendorPrinters specified. Creating a set of temporary printers with common device paths"
        paths = ['/dev/ttyUSB0', '/dev/ttyUSB1', '/dev/ttyUSB2', '/dev/usb/lp0', '/dev/usb/lp1', '/dev/usb/lp2', '/dev/salor-hospitality-front', '/dev/salor-hospitality-top', '/dev/salor-hospitality-back-top-left', '/dev/salor-hospitality-back-top-right', '/dev/salor-hospitality-back-bottom-left', '/dev/salor-hospitality-back-bottom-right']
        @vendor_printers = Array.new
        paths.size.times do |i|
          @vendor_printers << VendorPrinter.new(:name => paths[i].gsub(/^.*\//,''), :path => paths[i], :copies => 1, :codepage => 0)
        end
      end
    end

    def print(printer_id, text, raw_text_insertations={})
      return if @open_printers == {}
      Escper.log "[PRINTING]============"
      Escper.log "[PRINTING]PRINTING..."
      printer = @open_printers[printer_id]
      raise 'Mismatch between open_printers and printer_id' if printer.nil?

      codepage = printer[:codepage]
      codepage ||= 0
      output_text = Printer.merge_texts(text, raw_text_insertations, codepage)
      
      Escper.log "[PRINTING]  Printing on #{ printer[:name] } @ #{ printer[:device].inspect }."
      bytes_written = nil
      printer[:copies].times do |i|
        # The method .write works both for SerialPort object and File object, so we don't have to distinguish here.
        bytes_written = @open_printers[printer_id][:device].write output_text
        Escper.log "[PRINTING]ERROR: Byte count mismatch: sent #{text.length} written #{bytes_written}" unless output_text.length == bytes_written
      end
      # The method .flush works both for SerialPort object and File object, so we don't have to distinguish here. It is not really neccessary, since the close method will theoretically flush also.
      @open_printers[printer_id][:device].flush
      Escper.log "[PRINTING]  #{ output_text[0..60] }"
      return bytes_written, output_text
    end
    
    def self.merge_texts(text, raw_text_insertations, codepage = 0)
      asciifier = Escper::Asciifier.new(codepage)
      asciified_text = asciifier.process(text)
      raw_text_insertations.each do |key, value|
        markup = "{::escper}#{key.to_s}{:/}".encode('ASCII-8BIT')
        asciified_text.gsub!(markup, value)
      end
      return asciified_text
    end

    def identify(chartest=nil)
      Escper.log "[PRINTING]============"
      Escper.log "[PRINTING]TESTING Printers..."
      open
      @open_printers.each do |id, value|
        init = "\e@"
        cut = "\n\n\n\n\n\n" + "\x1D\x56\x00"
        testtext =
        "\e!\x38" +  # double tall, double wide, bold
        "#{ I18n.t :printing_test }\r\n" +
        "\e!\x00" +  # Font A
        "#{ value[:name] }\r\n" +
        "#{ value[:device].inspect }"
        
        Escper.log "[PRINTING]  Testing #{value[:device].inspect }"
        if chartest
          print(id, init + Escper::Asciifier.all_chars + cut)
        else
          ascifiier = Escper::Asciifier.new(value[:codepage])
          print(id, init + ascifiier.process(testtext) + cut)
        end
      end
      close
    end

    def open
      Escper.log "[PRINTING]============"
      Escper.log "[PRINTING]OPEN Printers..."
      @vendor_printers.size.times do |i|
        p = @vendor_printers[i]
        name = p.name
        path = p.path
        codepage = p.codepage
        baudrate = p.baudrate

        if Escper.use_safe_device_path == true
          sanitized_path = path.gsub(/[\/\s'"\&\^\$\#\!;\*]/,'_').gsub(/[^\w\/\.\-@]/,'')
          path = File.join(Escper.safe_device_path, @subdomain, "#{sanitized_path}.bill")
          @file_mode = 'ab'
        end

        Escper.log "[PRINTING]  Trying to open #{ name }@#{ path }@#{ baudrate }bps ..."
        pid = p.id ? p.id : i
        begin
          printer = SerialPort.new path, baudrate
          @open_printers.merge! pid => { :name => name, :path => path, :copies => p.copies, :device => printer, :codepage => codepage }
          Escper.log "[PRINTING]    Success for SerialPort: #{ printer.inspect }"
          next
        rescue Exception => e
          Escper.log "[PRINTING]    Failed to open as SerialPort: #{ e.inspect }"
        end

        begin
          printer = File.open path, @file_mode
          @open_printers.merge! pid => { :name => name, :path => path, :copies => p.copies, :device => printer, :codepage => codepage }
          Escper.log "[PRINTING]    Success for File: #{ printer.inspect }"
          next
        rescue Errno::EBUSY
          Escper.log "[PRINTING]    The File #{ path } is already open."
          Escper.log "[PRINTING]      Trying to reuse already opened printers."
          previously_opened_printers = @open_printers.clone
          previously_opened_printers.each do |key, val|
            Escper.log "[PRINTING]      Trying to reuse already opened File #{ key }: #{ val.inspect }"
            if val[:path] == p[:path] and val[:device].class == File
              Escper.log "[PRINTING]      Reused."
              @open_printers.merge! pid => { :name => name, :path => path, :copies => p.copies, :device => val[:device], :codepage => codepage }
              break
            end
          end
          unless @open_printers.has_key? p.id
            path = File.join(@fallback_root_path, 'tmp')
            printer = File.open(File.join(path, "#{ p.id }-#{ name }-fallback-busy.salor"), @file_mode)
            @open_printers.merge! pid => { :name => name, :path => path, :copies => p.copies, :device => printer, :codepage => codepage }
            Escper.log "[PRINTING]      Failed to open as either SerialPort or USB File and resource IS busy. This should not have happened. Created #{ printer.inspect } instead."
          end
          next
        rescue Exception => e
          path = File.join(@fallback_root_path, 'tmp')
          printer = File.open(File.join(path, "#{ p.id }-#{ name }-fallback-notbusy.salor"), @file_mode)
          @open_printers.merge! pid => { :name => name, :path => path, :copies => p.copies, :device => printer, :codepage => codepage }
          Escper.log "[PRINTING]    Failed to open as either SerialPort or USB File and resource is NOT busy. Created #{ printer.inspect } instead."
        end
      end
    end

    def close
      Escper.log "[PRINTING]============"
      Escper.log "[PRINTING]CLOSING Printers..."
      @open_printers.each do |key, value|
        begin
          value[:device].close
          Escper.log "[PRINTING]  Closing  #{ value[:name] } @ #{ value[:device].inspect }"
          @open_printers.delete(key)
        rescue Exception => e
          Escper.log "[PRINTING]  Error during closing of #{ value[:device] }: #{ e.inspect }"
        end
      end
    end
  end
end