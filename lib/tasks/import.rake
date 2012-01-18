# encoding: utf-8
namespace :import do

  desc "Imports images for products"
  task :images => :environment do
    files = `find db/init/assets -name "*.*"`.split("\n")
    count = 0
    files.each do |file|
      sku = file.split("/").last.split("_").first
      print "#{sku} "
      variant = Variant.where({:sku => sku}).first
      product = nil
      unless variant.nil?
        product = variant.product
      end
      unless product.nil?
        f = File.open(file)
        image = Image.new(:attachment => f, :viewable_id => product.id, :viewable_type => 'Product', :alt => product.name)
        image.save!
      end
      count += 1
      puts "#{count}/#{files.count}"
    end
  end

end