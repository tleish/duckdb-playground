#!/usr/bin/env ruby
# Generates large mock small-parcel shipments CSVs, one per month, in
# parallel (one process per month), plus two small lookup files
# (customers.csv, products.csv) that shipments join back to.
#
# Usage:
#   ruby generate_shipments.rb [target_size_mb_per_file]
#
# Defaults to 300 MB per file, written to data/shipments_2026_01.csv
# through data/shipments_2026_06.csv. parcel_transaction_id is unique
# across all files: each month is given a reserved block of IDs
# (ID_BLOCK_SIZE apart) since the files are generated concurrently and
# can't share a running counter.

require "date"

TARGET_MB = (ARGV[0] || 300).to_i
TARGET_BYTES = TARGET_MB * 1024 * 1024
BATCH_SIZE = 50_000
MONTHS = (1..6).map { |month| [2026, month] }
ID_BLOCK_SIZE = 20_000_000

# DuckDB's CSV sniffer only scans the leading rows of the file to guess the
# date format. If every day-of-month in that window is <= 12, m/d and d/m are
# both consistent and it locks in the wrong one; a later day > 12 then fails
# to convert. Keeping the first rows ambiguous reproduces that failure mode
# instead of requiring an explicit timestampformat in read_csv.
#
# The first month's file (month_index 0) is exempt, so at least one shipments
# file sniffs cleanly and can be used as a known-good baseline.
AMBIGUOUS_SAMPLE_ROWS = 25_000

# (name, parent_name). parent_name nil marks a root customer; others nest
# under an earlier name in this list, up to 3 levels deep. Written out as an
# "ancestry" materialized path (e.g. "1/5"), same convention as the Ruby
# ancestry gem, so customers.csv is a tree instead of a flat lookup.
CUSTOMERS = [
  ["Acme Logistics", nil],
  ["Northwind Traders", nil],
  ["Blue Ridge Supply", nil],
  ["Pinecrest Retail", nil],
  ["Summit Distribution", "Acme Logistics"],
  ["Cascade Freight", "Acme Logistics"],
  ["Harbor Point Goods", "Northwind Traders"],
  ["Redwood Mercantile", "Northwind Traders"],
  ["Silverline Commerce", "Blue Ridge Supply"],
  ["Ironclad Shipping", "Blue Ridge Supply"],
  ["Maple & Co", "Pinecrest Retail"],
  ["Vantage Wholesale", "Pinecrest Retail"],
  ["Coastal Fulfillment", "Acme Logistics"],
  ["Granite Peak Traders", "Northwind Traders"],
  ["Meridian Supply Co", "Summit Distribution"],
  ["Outerspace Depot", "Summit Distribution"],
  ["Timberline Goods", "Harbor Point Goods"],
  ["Riverside Parcel Co", "Silverline Commerce"],
  ["Amberlight Trading", "Maple & Co"],
  ["Sable Creek Supply", "Vantage Wholesale"],
]

# What's inside the parcel: (name, category). customer_id/product_id on each
# shipment row join back to customers.csv/products.csv below.
PRODUCTS = [
  ["Wireless Earbuds", "Electronics"], ["Bluetooth Speaker", "Electronics"],
  ["USB-C Charger", "Electronics"], ["Mechanical Keyboard", "Electronics"],
  ["4K Webcam", "Electronics"], ["Ceramic Mug Set", "Home"],
  ["Linen Throw Blanket", "Home"], ["Cast Iron Skillet", "Home"],
  ["Scented Candle Trio", "Home"], ["Bamboo Cutting Board", "Home"],
  ["Cotton T-Shirt", "Apparel"], ["Merino Wool Socks", "Apparel"],
  ["Denim Jacket", "Apparel"], ["Running Shorts", "Apparel"],
  ["Knit Beanie", "Apparel"], ["Insulated Water Bottle", "Outdoors"],
  ["Trekking Poles", "Outdoors"], ["Headlamp", "Outdoors"],
  ["Packable Rain Jacket", "Outdoors"], ["Camping Hammock", "Outdoors"],
]

CARRIERS = ["USPS", "UPS", "FedEx", "DHL"]
SERVICE_LEVELS = ["Ground", "Priority", "Express", "First Class"]
DELIVERY_STATUSES = ["Delivered", "In Transit", "Exception", "Returned"]

ZIP_RANGE = 10_000..99_999
ZONE_RANGE = 1..8
WEIGHT_OZ_RANGE = 1.0..160.0
TRACKING_NUMBER_RANGE = 10**10..(10**11 - 1)
CUSTOMER_COST_RANGE = 3.5..500.0
NSA_COST_RATIO_RANGE = 0.5..0.85
NET_MARGIN_RATIO_RANGE = 0.6..0.9

COLUMNS = {
  "customer_id" => "%d",
  "product_id" => "%d",
  "shipped_at" => "%02d/%02d/%04d %02d:%02d:%02d",
  "parcel_transaction_id" => "%d",
  "carrier" => "%s",
  "service_level" => "%s",
  "origin_zip" => "%05d",
  "destination_zip" => "%05d",
  "zone" => "%d",
  "weight_oz" => "%.1f",
  "tracking_number" => "%s%d",
  "customer_cost" => "%.2f",
  "nsa_cost" => "%.2f",
  "gross_margin" => "%.2f",
  "net_margin" => "%.2f",
  "delivery_status" => "%s",
}

HEADER = COLUMNS.keys
ROW_FORMAT = "#{COLUMNS.values.join(",")}\n"

Dir.mkdir("data") unless Dir.exist?("data")

File.open("data/customers.csv", "w") do |file|
  file.puts "id,ancestry,name"
  id_by_name = {}
  ancestry_by_name = {}

  CUSTOMERS.each_with_index do |(name, parent_name), index|
    id = index + 1
    ancestry = if parent_name.nil?
      nil
    elsif ancestry_by_name[parent_name]
      "#{ancestry_by_name[parent_name]}/#{id_by_name[parent_name]}"
    else
      id_by_name[parent_name].to_s
    end

    id_by_name[name] = id
    ancestry_by_name[name] = ancestry

    file.puts "#{id},#{ancestry},#{name}"
  end
end

File.open("data/products.csv", "w") do |file|
  file.puts "id,name,category"
  PRODUCTS.each_with_index do |(name, category), index|
    file.puts "#{index + 1},#{name},#{category}"
  end
end

MONTHS.each_with_index do |(year, month), month_index|
  fork do
    srand

    output_file = format("data/shipments_%04d_%02d.csv", year, month)
    days_in_month = Date.new(year, month, -1).day
    parcel_transaction_id = month_index * ID_BLOCK_SIZE
    row_number_in_file = 0

    File.open(output_file, "w") do |file|
      file.puts HEADER.join(",")

      loop do
        buffer = String.new
        BATCH_SIZE.times do
          parcel_transaction_id += 1
          row_number_in_file += 1

          day_max = (month_index.zero? || row_number_in_file > AMBIGUOUS_SAMPLE_ROWS) ? days_in_month : 12
          carrier = CARRIERS.sample
          customer_cost = rand(CUSTOMER_COST_RANGE)
          nsa_cost = customer_cost * rand(NSA_COST_RATIO_RANGE)
          gross_margin = customer_cost - nsa_cost
          net_margin = gross_margin * rand(NET_MARGIN_RATIO_RANGE)

          buffer << format(
            ROW_FORMAT,
            rand(1..CUSTOMERS.size),                                    # customer_id
            rand(1..PRODUCTS.size),                                     # product_id
            month, rand(1..day_max), year, rand(0..23), rand(0..59), rand(0..59), # shipped_at
            parcel_transaction_id,                                      # parcel_transaction_id
            carrier,                                                    # carrier
            SERVICE_LEVELS.sample,                                      # service_level
            rand(ZIP_RANGE),                                            # origin_zip
            rand(ZIP_RANGE),                                            # destination_zip
            rand(ZONE_RANGE),                                           # zone
            rand(WEIGHT_OZ_RANGE),                                      # weight_oz
            carrier[0, 2].upcase, rand(TRACKING_NUMBER_RANGE),          # tracking_number
            customer_cost,                                              # customer_cost
            nsa_cost,                                                   # nsa_cost
            gross_margin,                                               # gross_margin
            net_margin,                                                 # net_margin
            DELIVERY_STATUSES.sample                                    # delivery_status
          )
        end
        file.write(buffer)
        break if File.size(output_file) >= TARGET_BYTES
      end
    end

    size_mb = (File.size(output_file) / (1024.0 * 1024)).round(1)
    puts "Wrote #{row_number_in_file} rows (#{size_mb} MB) to #{output_file}"
  end
end

results = Process.waitall
failures = results.reject { |_pid, status| status.success? }
abort("#{failures.size} of #{MONTHS.size} generator process(es) failed") unless failures.empty?
