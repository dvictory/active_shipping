# -*- encoding: utf-8 -*-

module ActiveMerchant
  module Shipping
    class UPS < Carrier
      self.retry_safe = true
      
      cattr_accessor :default_options
      cattr_reader :name
      @@name = "UPS"
      
      TEST_URL = 'https://wwwcie.ups.com'
      LIVE_URL = 'https://onlinetools.ups.com'
      
      RESOURCES = {
        :rates => 'ups.app/xml/Rate',
        :track => 'ups.app/xml/Track',
        :ship_confirm=>'ups.app/xml/ShipConfirm',
        :ship_void=>'ups.app/xml/Void',
        :ship_accept=>'ups.app/xml/ShipAccept'
      }
      
      PICKUP_CODES = HashWithIndifferentAccess.new({
        :daily_pickup => "01",
        :customer_counter => "03", 
        :one_time_pickup => "06",
        :on_call_air => "07",
        :suggested_retail_rates => "11",
        :letter_center => "19",
        :air_service_center => "20"
      })

      CUSTOMER_CLASSIFICATIONS = HashWithIndifferentAccess.new({
        :wholesale => "01",
        :occasional => "03", 
        :retail => "04"
      })

      # these are the defaults described in the UPS API docs,
      # but they don't seem to apply them under all circumstances,
      # so we need to take matters into our own hands
      DEFAULT_CUSTOMER_CLASSIFICATIONS = Hash.new do |hash,key|
        hash[key] = case key.to_sym
        when :daily_pickup then :wholesale
        when :customer_counter then :retail
        else
          :occasional
        end
      end
      
      DEFAULT_SERVICES = {
        "01" => "UPS Next Day Air",
        "02" => "UPS Second Day Air",
        "03" => "UPS Ground",
        "07" => "UPS Worldwide Express",
        "08" => "UPS Worldwide Expedited",
        "11" => "UPS Standard",
        "12" => "UPS Three-Day Select",
        "13" => "UPS Next Day Air Saver",
        "14" => "UPS Next Day Air Early A.M.",
        "54" => "UPS Worldwide Express Plus",
        "59" => "UPS Second Day Air A.M.",
        "65" => "UPS Saver",
        "82" => "UPS Today Standard",
        "83" => "UPS Today Dedicated Courier",
        "84" => "UPS Today Intercity",
        "85" => "UPS Today Express",
        "86" => "UPS Today Express Saver"
      }
      
      CANADA_ORIGIN_SERVICES = {
        "01" => "UPS Express",
        "02" => "UPS Expedited",
        "14" => "UPS Express Early A.M."
      }
      
      MEXICO_ORIGIN_SERVICES = {
        "07" => "UPS Express",
        "08" => "UPS Expedited",
        "54" => "UPS Express Plus"
      }
      
      EU_ORIGIN_SERVICES = {
        "07" => "UPS Express",
        "08" => "UPS Expedited"
      }
      
      OTHER_NON_US_ORIGIN_SERVICES = {
        "07" => "UPS Express"
      }

      TRACKING_STATUS_CODES = HashWithIndifferentAccess.new({
        'I' => :in_transit,
        'D' => :delivered,
        'X' => :exception,
        'P' => :pickup,
        'M' => :manifest_pickup
      })

      # From http://en.wikipedia.org/w/index.php?title=European_Union&oldid=174718707 (Current as of November 30, 2007)
      EU_COUNTRY_CODES = ["GB", "AT", "BE", "BG", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE"]
      
      US_TERRITORIES_TREATED_AS_COUNTRIES = ["AS", "FM", "GU", "MH", "MP", "PW", "PR", "VI"]
      
      def requirements
        [:key, :login, :password]
      end
      
      def find_rates(origin, destination, packages, options={})
        origin, destination = upsified_location(origin), upsified_location(destination)
        options = @options.merge(options)
        packages = Array(packages)
        access_request = build_access_request
        rate_request = build_rate_request(origin, destination, packages, options)
        response = commit(:rates, save_request(access_request + rate_request), (options[:test] || false))
        parse_rate_response(origin, destination, packages, response, options)
      end
      
      def find_tracking_info(tracking_number, options={})
        options = @options.update(options)
        access_request = build_access_request
        tracking_request = build_tracking_request(tracking_number, options)
        response = commit(:track, save_request(access_request + tracking_request), (options[:test] || false))
        parse_tracking_response(response, options)
      end


      #Derek added to get shipping labels
      def ship_confirm(origin,destination,packages,options={})
        origin, destination = upsified_location(origin), upsified_location(destination)
        access_request = build_access_request
        ship_confirm_request = build_ship_confirm_request(origin,destination,packages,options)
        response = commit(:ship_confirm, save_request(access_request + ship_confirm_request), (options[:test] || false))
        parse_ship_confirm_response(response,options)
      end

      def ship_accept(digest,options={})
        access_request = build_access_request
        ship_accept_request = build_ship_accept_request(digest)
        response = commit(:ship_accept, save_request(access_request + ship_accept_request), (options[:test] || false))
        parse_ship_accept_response(response)
      end

      def ship_void(shipment_number,tracking_numbers,options={})
        access_request = build_access_request
        ship_void_request = build_ship_void_request(shipment_number,tracking_numbers)
        response = commit(:ship_void, save_request("<?xml version=\"1.0\" ?>" + access_request+"<?xml version=\"1.0\" ?>"+ship_void_request), (options[:test] || false))
        parse_ship_void_response(response)
      end


      protected
      
      def upsified_location(location)
        if location.country_code == 'US' && US_TERRITORIES_TREATED_AS_COUNTRIES.include?(location.state)
          atts = {:country => location.state}
          [:zip, :city, :address1, :address2, :address3, :phone, :fax, :address_type].each do |att|
            atts[att] = location.send(att)
          end
          Location.new(atts)
        else
          location
        end
      end
      
      def build_access_request
        xml_request = XmlNode.new('AccessRequest') do |access_request|
          access_request << XmlNode.new('AccessLicenseNumber', @options[:key])
          access_request << XmlNode.new('UserId', @options[:login])
          access_request << XmlNode.new('Password', @options[:password])
        end
        xml_request.to_s
      end
      
      def build_rate_request(origin, destination, packages, options={})
        packages = Array(packages)
        xml_request = XmlNode.new('RatingServiceSelectionRequest') do |root_node|
          root_node << XmlNode.new('Request') do |request|
            request << XmlNode.new('RequestAction', 'Rate')
            request << XmlNode.new('RequestOption', 'Shop')
            # not implemented: 'Rate' RequestOption to specify a single service query
            # request << XmlNode.new('RequestOption', ((options[:service].nil? or options[:service] == :all) ? 'Shop' : 'Rate'))
          end
          
          pickup_type = options[:pickup_type] || :daily_pickup
          
          root_node << XmlNode.new('PickupType') do |pickup_type_node|
            pickup_type_node << XmlNode.new('Code', PICKUP_CODES[pickup_type])
            # not implemented: PickupType/PickupDetails element
          end
          cc = options[:customer_classification] || DEFAULT_CUSTOMER_CLASSIFICATIONS[pickup_type]
          root_node << XmlNode.new('CustomerClassification') do |cc_node|
            cc_node << XmlNode.new('Code', CUSTOMER_CLASSIFICATIONS[cc])
          end
          
          root_node << XmlNode.new('Shipment') do |shipment|
            # not implemented: Shipment/Description element
            shipment << build_location_node('Shipper', (options[:shipper] || origin), options)
            shipment << build_location_node('ShipTo', destination, options)
            if options[:shipper] and options[:shipper] != origin
              shipment << build_location_node('ShipFrom', origin, options)
            end
            
            # not implemented:  * Shipment/ShipmentWeight element
            #                   * Shipment/ReferenceNumber element                    
            #                   * Shipment/Service element                            
            #                   * Shipment/PickupDate element                         
            #                   * Shipment/ScheduledDeliveryDate element              
            #                   * Shipment/ScheduledDeliveryTime element              
            #                   * Shipment/AlternateDeliveryTime element              
            #                   * Shipment/DocumentsOnly element                      
            
            packages.each do |package|
              imperial = ['US','LR','MM'].include?(origin.country_code(:alpha2))
              
              shipment << XmlNode.new("Package") do |package_node|
                
                # not implemented:  * Shipment/Package/PackagingType element
                #                   * Shipment/Package/Description element
                
                package_node << XmlNode.new("PackagingType") do |packaging_type|
                  packaging_type << XmlNode.new("Code", '02')
                end
                
                package_node << XmlNode.new("Dimensions") do |dimensions|
                  dimensions << XmlNode.new("UnitOfMeasurement") do |units|
                    units << XmlNode.new("Code", imperial ? 'IN' : 'CM')
                  end
                  [:length,:width,:height].each do |axis|
                    value = ((imperial ? package.inches(axis) : package.cm(axis)).to_f*1000).round/1000.0 # 3 decimals
                    dimensions << XmlNode.new(axis.to_s.capitalize, [value,0.1].max)
                  end
                end
              
                package_node << XmlNode.new("PackageWeight") do |package_weight|
                  package_weight << XmlNode.new("UnitOfMeasurement") do |units|
                    units << XmlNode.new("Code", imperial ? 'LBS' : 'KGS')
                  end
                  
                  value = ((imperial ? package.lbs : package.kgs).to_f*1000).round/1000.0 # 3 decimals
                  package_weight << XmlNode.new("Weight", [value,0.1].max)
                end
              
                # not implemented:  * Shipment/Package/LargePackageIndicator element
                #                   * Shipment/Package/ReferenceNumber element
                #                   * Shipment/Package/PackageServiceOptions element
                #                   * Shipment/Package/AdditionalHandling element  
              end
              
            end
            
            # not implemented:  * Shipment/ShipmentServiceOptions element
            #                   * Shipment/RateInformation element
            
          end
          
        end
        xml_request.to_s
      end
      
      def build_tracking_request(tracking_number, options={})
        xml_request = XmlNode.new('TrackRequest') do |root_node|
          root_node << XmlNode.new('Request') do |request|
            request << XmlNode.new('RequestAction', 'Track')
            request << XmlNode.new('RequestOption', '1')
          end
          root_node << XmlNode.new('TrackingNumber', tracking_number.to_s)
        end
        xml_request.to_s
      end

      #DV added
      def build_ship_confirm_request(origin, destination, packages, options={})
        packages = Array(packages)
        xml_request = XmlNode.new('ShipmentConfirmRequest') do |root_node|
          root_node << XmlNode.new('Request') do |request|
            request << XmlNode.new('RequestAction', 'ShipConfirm')
            request << XmlNode.new('RequestOption', 'nonvalidate')
            # not implemented: 'Rate' RequestOption to specify a single service query
            # request << XmlNode.new('RequestOption', ((options[:service].nil? or options[:service] == :all) ? 'Shop' : 'Rate'))
          end

          #Label spec
          root_node << XmlNode.new('LabelSpecification') do |label_node|
            label_node << XmlNode.new('LabelPrintMethod') do |label_method|
              label_method << XmlNode.new('Code', "GIF")
              label_method << XmlNode.new('Description', "gif")
            end
            label_node << XmlNode.new('HTTPUserAgent', "Mozilla/4.5")
            label_node << XmlNode.new('LabelImageFormat') do |label_method|
              label_method << XmlNode.new('Code', "GIF")
              label_method << XmlNode.new('Description', "gif")
            end
            # not implemented: PickupType/PickupDetails element
          end

          #Shipment Section
          root_node << XmlNode.new('Shipment') do |shipment|
            # not implemented: Shipment/Description element
            shipment << XmlNode.new('RateInformation') do |ri|
              ri << XmlNode.new('NegotiatedRatesIndicator')
            end
            shipment << build_ups_location_node('Shipper', (options[:shipper] || origin), options)
            shipment << build_ups_location_node('ShipTo', destination, options)
            #if options[:shipper] and options[:shipper] != origin
            shipment << build_ups_location_node('ShipFrom', origin, options)
            #end

            # not implemented:  * Shipment/ShipmentWeight element
            #                   * Shipment/ReferenceNumber element
            #                   * Shipment/Service element
            #                   * Shipment/PickupDate element
            #                   * Shipment/ScheduledDeliveryDate element
            #                   * Shipment/ScheduledDeliveryTime element
            #                   * Shipment/AlternateDeliveryTime element
            #                   * Shipment/DocumentsOnly element

            #DV Payment Element
            shipment << XmlNode.new("PaymentInformation") do |payment_node|
              payment_node << XmlNode.new('Prepaid') do |prepaid_node|
                prepaid_node << XmlNode.new('BillShipper') do |bill_node|
                  bill_node << XmlNode.new('AccountNumber',options[:origin_account])
                end
              end

            end

            #DV Service Element
            shipment << XmlNode.new("Service") do |service_node|
              service_node << XmlNode.new('Code', options[:shipping_method])
              service_node << XmlNode.new('Description', DEFAULT_SERVICES[@options[:shipping_method]])
            end

            packages.each do |package|
              imperial = ['US','LR','MM'].include?(origin.country_code(:alpha2))

              shipment << XmlNode.new("Package") do |package_node|

                # not implemented:  * Shipment/Package/PackagingType element
                #                   * Shipment/Package/Description element

                package_node << XmlNode.new("PackagingType") do |packaging_type|
                  packaging_type << XmlNode.new("Code", '02')
                  packaging_type << XmlNode.new("Description", 'User Description')
                end
                package_node << XmlNode.new("Description", 'Package Description')
                package_node << XmlNode.new("Dimensions") do |dimensions|
                  dimensions << XmlNode.new("UnitOfMeasurement") do |units|
                    units << XmlNode.new("Code", imperial ? 'IN' : 'CM')
                  end
                  [:length,:width,:height].each do |axis|
                    value = ((imperial ? package.inches(axis) : package.cm(axis)).to_f*1000).round/1000.0 # 3 decimals
                    dimensions << XmlNode.new(axis.to_s.capitalize, [value,0.1].max)
                  end
                end

                package_node << XmlNode.new("PackageWeight") do |package_weight|
                  package_weight << XmlNode.new("UnitOfMeasurement") do |units|
                    units << XmlNode.new("Code", imperial ? 'LBS' : 'KGS')
                  end

                  value = ((imperial ? package.lbs : package.kgs).to_f*1000).round/1000.0 # 3 decimals
                  package_weight << XmlNode.new("Weight", [value,0.1].max)
                end
                unless package.value.blank?
                  package_node << XmlNode.new("PackageServiceOptions") do |package_service|
                    package_service << XmlNode.new("InsuredValue") do |iv|
                      iv << XmlNode.new("CurrentCode",package.currency)
                      iv << XmlNode.new("MonetaryValue",package.value)
                    end
                  end
                end
                package_node << XmlNode.new("AdditionalHandling","0")

                # not implemented:  * Shipment/Package/LargePackageIndicator element
                #                   * Shipment/Package/ReferenceNumber element
                #                   * Shipment/Package/PackageServiceOptions element
                #                   * Shipment/Package/AdditionalHandling element
              end

            end

            #                   * Shipment/RateInformation element
          end

        end
        xml_request.to_s
      end

      def build_ship_accept_request(digest,options={})
        xml_request = XmlNode.new('ShipmentAcceptRequest') do |root_node|
          root_node << XmlNode.new('Request') do |request|
            request << XmlNode.new('RequestAction', 'ShipAccept')
          end
          root_node << XmlNode.new('ShipmentDigest',digest)
        end
        xml_request.to_s
      end

      def build_ship_void_request(shipment_number,tracking_numbers,options={})
        xml_request = XmlNode.new('VoidShipmentRequest') do |root_node|
          root_node << XmlNode.new('Request') do |request|
            request << XmlNode.new('RequestAction', 'Void')
          end
          root_node << XmlNode.new('ExpandedVoidShipment') do |void_shipment_node|
            void_shipment_node << XmlNode.new('ShipmentIdentificationNumber', shipment_number)
            tracking_numbers.each do |tn|
              void_shipment_node << XmlNode.new('TrackingNumber', tn)
            end
          end
        end
        xml_request.to_s
      end

      def build_location_node(name,location,options={})
        # not implemented:  * Shipment/Shipper/Name element
        #                   * Shipment/(ShipTo|ShipFrom)/CompanyName element
        #                   * Shipment/(Shipper|ShipTo|ShipFrom)/AttentionName element
        #                   * Shipment/(Shipper|ShipTo|ShipFrom)/TaxIdentificationNumber element
        location_node = XmlNode.new(name) do |location_node|
          location_node << XmlNode.new('Name', location.name) unless location.name.blank?
          location_node << XmlNode.new('CompanyName', location.company_name) unless location.company_name.blank?
          location_node << XmlNode.new('PhoneNumber', location.phone.gsub(/[^\d]/,'')) unless location.phone.blank?
          location_node << XmlNode.new('FaxNumber', location.fax.gsub(/[^\d]/,'')) unless location.fax.blank?
          
          if name == 'Shipper' and (origin_account = @options[:origin_account] || options[:origin_account])
            location_node << XmlNode.new('ShipperNumber', origin_account)
          elsif name == 'ShipTo' and (destination_account = @options[:destination_account] || options[:destination_account])
            location_node << XmlNode.new('ShipperAssignedIdentificationNumber', destination_account)
          end
          
          location_node << XmlNode.new('Address') do |address|
            address << XmlNode.new("AddressLine1", location.address1) unless location.address1.blank?
            address << XmlNode.new("AddressLine2", location.address2) unless location.address2.blank?
            address << XmlNode.new("AddressLine3", location.address3) unless location.address3.blank?
            address << XmlNode.new("City", location.city) unless location.city.blank?
            address << XmlNode.new("StateProvinceCode", location.province) unless location.province.blank?
              # StateProvinceCode required for negotiated rates but not otherwise, for some reason
            address << XmlNode.new("PostalCode", location.postal_code) unless location.postal_code.blank?
            address << XmlNode.new("CountryCode", location.country_code(:alpha2)) unless location.country_code(:alpha2).blank?
            address << XmlNode.new("ResidentialAddressIndicator", true) unless location.commercial? # the default should be that UPS returns residential rates for destinations that it doesn't know about
            # not implemented: Shipment/(Shipper|ShipTo|ShipFrom)/Address/ResidentialAddressIndicator element
          end
        end
      end

      def build_ups_location_node(name,location,options={})
        # not implemented:  * Shipment/Shipper/Name element
        #                   * Shipment/(ShipTo|ShipFrom)/CompanyName element
        #                   * Shipment/(Shipper|ShipTo|ShipFrom)/AttentionName element
        #                   * Shipment/(Shipper|ShipTo|ShipFrom)/TaxIdentificationNumber element
        location_node = XmlNode.new(name) do |location_node|
          location_node << XmlNode.new('Name', location.name) unless location.name.blank?
          location_node << XmlNode.new('CompanyName', location.company_name) unless location.company_name.blank?
          location_node << XmlNode.new('PhoneNumber', location.phone.gsub(/[^\d]/,'')) unless location.phone.blank?
          location_node << XmlNode.new('FaxNumber', location.fax.gsub(/[^\d]/,'')) unless location.fax.blank?

          if name == 'Shipper' and (origin_account = @options[:origin_account] || options[:origin_account])
            location_node << XmlNode.new('ShipperNumber', origin_account)
          elsif name == 'ShipTo' and (destination_account = @options[:destination_account] || options[:destination_account])
            location_node << XmlNode.new('ShipperAssignedIdentificationNumber', destination_account)
          end

          location_node << XmlNode.new('Address') do |address|
            address << XmlNode.new("AddressLine1", location.address1) unless location.address1.blank?
            address << XmlNode.new("AddressLine2", location.address2) unless location.address2.blank?
            address << XmlNode.new("AddressLine3", location.address3) unless location.address3.blank?
            address << XmlNode.new("City", location.city) unless location.city.blank?
            address << XmlNode.new("StateProvinceCode", location.province) unless location.province.blank?
              # StateProvinceCode required for negotiated rates but not otherwise, for some reason
            address << XmlNode.new("PostalCode", location.postal_code) unless location.postal_code.blank?
            address << XmlNode.new("CountryCode", location.country_code(:alpha2)) unless location.country_code(:alpha2).blank?
            address << XmlNode.new("ResidentialAddressIndicator", true) unless location.commercial? # the default should be that UPS returns residential rates for destinations that it doesn't know about
            # not implemented: Shipment/(Shipper|ShipTo|ShipFrom)/Address/ResidentialAddressIndicator element
          end
        end
      end
      
      def parse_rate_response(origin, destination, packages, response, options={})
        rates = []
        
        xml = REXML::Document.new(response)
        success = response_success?(xml)
        message = response_message(xml)
        
        if success
          rate_estimates = []
          
          xml.elements.each('/*/RatedShipment') do |rated_shipment|
            service_code = rated_shipment.get_text('Service/Code').to_s
            days_to_delivery = rated_shipment.get_text('GuaranteedDaysToDelivery').to_s.to_i
            days_to_delivery = nil if days_to_delivery == 0

            rate_estimates << RateEstimate.new(origin, destination, @@name,
                                service_name_for(origin, service_code),
                                :total_price => rated_shipment.get_text('TotalCharges/MonetaryValue').to_s.to_f,
                                :currency => rated_shipment.get_text('TotalCharges/CurrencyCode').to_s,
                                :service_code => service_code,
                                :packages => packages,
                                :delivery_range => [timestamp_from_business_day(days_to_delivery)])
          end
        end
        RateResponse.new(success, message, Hash.from_xml(response).values.first, :rates => rate_estimates, :xml => response, :request => last_request)
      end
      
      def parse_tracking_response(response, options={})
        xml = REXML::Document.new(response)
        success = response_success?(xml)
        message = response_message(xml)
        
        if success
          tracking_number, origin, destination, status_code, status_description = nil
          delivered, exception = false
          exception_event = nil
          shipment_events = []
          status = {}
          scheduled_delivery_date = nil

          first_shipment = xml.elements['/*/Shipment']
          first_package = first_shipment.elements['Package']
          tracking_number = first_shipment.get_text('ShipmentIdentificationNumber | Package/TrackingNumber').to_s
          
          # Build status hash
          status_node = first_package.elements['Activity/Status/StatusType']
          status_code = status_node.get_text('Code').to_s
          status_description = status_node.get_text('Description').to_s
          status = TRACKING_STATUS_CODES[status_code]

          if status_description =~ /out.*delivery/i
            status = :out_for_delivery
          end

          origin, destination = %w{Shipper ShipTo}.map do |location|
            location_from_address_node(first_shipment.elements["#{location}/Address"])
          end

          # Get scheduled delivery date
          unless status == :delivered
            scheduled_delivery_date = parse_ups_datetime({
              :date => first_shipment.get_text('ScheduledDeliveryDate'),
              :time => nil
              })
          end

          activities = first_package.get_elements('Activity')
          unless activities.empty?
            shipment_events = activities.map do |activity|
              description = activity.get_text('Status/StatusType/Description').to_s
              zoneless_time = if (time = activity.get_text('Time')) &&
                                 (date = activity.get_text('Date'))
                time, date = time.to_s, date.to_s
                hour, minute, second = time.scan(/\d{2}/)
                year, month, day = date[0..3], date[4..5], date[6..7]
                Time.utc(year, month, day, hour, minute, second)
              end
              location = location_from_address_node(activity.elements['ActivityLocation/Address'])
              ShipmentEvent.new(description, zoneless_time, location)
            end
            
            shipment_events = shipment_events.sort_by(&:time)
            
            # UPS will sometimes archive a shipment, stripping all shipment activity except for the delivery 
            # event (see test/fixtures/xml/delivered_shipment_without_events_tracking_response.xml for an example).
            # This adds an origin event to the shipment activity in such cases.
            if origin && !(shipment_events.count == 1 && status == :delivered)
              first_event = shipment_events[0]
              same_country = origin.country_code(:alpha2) == first_event.location.country_code(:alpha2)
              same_or_blank_city = first_event.location.city.blank? or first_event.location.city == origin.city
              origin_event = ShipmentEvent.new(first_event.name, first_event.time, origin)
              if same_country and same_or_blank_city
                shipment_events[0] = origin_event
              else
                shipment_events.unshift(origin_event)
              end
            end

            # Has the shipment been delivered?
            if status == :delivered
              if !destination
                destination = shipment_events[-1].location
              end
              shipment_events[-1] = ShipmentEvent.new(shipment_events.last.name, shipment_events.last.time, destination)
            end
          end
          
        end
        TrackingResponse.new(success, message, Hash.from_xml(response).values.first,
          :carrier => @@name,
          :xml => response,
          :request => last_request,
          :status => status,
          :status_code => status_code,
          :status_description => status_description,
          :scheduled_delivery_date => scheduled_delivery_date,
          :shipment_events => shipment_events,
          :delivered => delivered,
          :exception => exception,
          :exception_event => exception_event,
          :origin => origin,
          :destination => destination,
          :tracking_number => tracking_number)
      end

      #DV added
      def parse_ship_confirm_response(response, options={})
        xml = REXML::Document.new(response)
        success = response_success?(xml)
        message = response_message(xml)
        ret = Hash.new
        if success
          ret[:digest] = xml.elements['//ShipmentConfirmResponse/ShipmentDigest'][0].to_s
          ret[:shipment_charges]=xml.elements['//ShipmentConfirmResponse/ShipmentCharges/TotalCharges/MonetaryValue'][0].to_s
          ret[:shipment_number]=xml.elements['//ShipmentConfirmResponse/ShipmentIdentificationNumber'][0].to_s
          ret[:shipment_weight]=xml.elements['//ShipmentConfirmResponse/BillingWeight/Weight'][0].to_s
          ret
        else
          message
        end
      end

      def parse_ship_accept_response(response_to_parse)
        xml = REXML::Document.new(response_to_parse)
        success = response_success?(xml)
        message = response_message(xml)
        puts xml
        if success
          response = Hash.new
          response[:shipment_number] = xml.elements["//ShipmentAcceptResponse/ShipmentResults/ShipmentIdentificationNumber"][0].to_s
          response[:tracking_number] = xml.elements["//ShipmentAcceptResponse/ShipmentResults/PackageResults/TrackingNumber"][0].to_s
          response[:encoded_image] = xml.elements["//ShipmentAcceptResponse/ShipmentResults/PackageResults/LabelImage/GraphicImage"][0].to_s

          if !xml.elements["//ShipmentAcceptResponse/ShipmentResults/ControlLogReceipt/GraphicImage"].nil?
            hvr = xml.elements["//ShipmentAcceptResponse/ShipmentResults/ControlLogReceipt/GraphicImage"][0].to_s
            response[:high_value_report_encoded] = hvr
          end

          response
        else
          message
        end


      end

      def parse_ship_void_response(response_to_parse)
        xml = REXML::Document.new(response_to_parse)
        success = response_success?(xml)
        message = response_message(xml)

        message

      end
      
      def location_from_address_node(address)
        return nil unless address
        Location.new(
                :country =>     node_text_or_nil(address.elements['CountryCode']),
                :postal_code => node_text_or_nil(address.elements['PostalCode']),
                :province =>    node_text_or_nil(address.elements['StateProvinceCode']),
                :city =>        node_text_or_nil(address.elements['City']),
                :address1 =>    node_text_or_nil(address.elements['AddressLine1']),
                :address2 =>    node_text_or_nil(address.elements['AddressLine2']),
                :address3 =>    node_text_or_nil(address.elements['AddressLine3'])
              )
      end
      
      def parse_ups_datetime(options = {})
        time, date = options[:time].to_s, options[:date].to_s
        if time.nil?
          hour, minute, second = 0
        else
          hour, minute, second = time.scan(/\d{2}/)
        end
        year, month, day = date[0..3], date[4..5], date[6..7]

        Time.utc(year, month, day, hour, minute, second)
      end

      def response_success?(xml)
        xml.get_text('/*/Response/ResponseStatusCode').to_s == '1'
      end
      
      def response_message(xml)
        xml.get_text('/*/Response/Error/ErrorDescription | /*/Response/ResponseStatusDescription').to_s
      end
      
      def commit(action, request, test = false)
        puts "Posting to #{"#{test ? TEST_URL : LIVE_URL}/#{RESOURCES[action]}"}"
        ssl_post("#{test ? TEST_URL : LIVE_URL}/#{RESOURCES[action]}", request)
      end
      
      
      def service_name_for(origin, code)
        origin = origin.country_code(:alpha2)
        
        name = case origin
        when "CA" then CANADA_ORIGIN_SERVICES[code]
        when "MX" then MEXICO_ORIGIN_SERVICES[code]
        when *EU_COUNTRY_CODES then EU_ORIGIN_SERVICES[code]
        end
        
        name ||= OTHER_NON_US_ORIGIN_SERVICES[code] unless name == 'US'
        name ||= DEFAULT_SERVICES[code]
      end
      
    end
  end
end
