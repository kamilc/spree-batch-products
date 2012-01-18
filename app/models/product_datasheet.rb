class ProductDatasheet < ActiveRecord::Base
  require 'spreadsheet'
  require 'iconv'
  
  attr_accessor :queries_failed, :records_failed, :records_matched, :records_updated
  
  before_save :update_statistics
  
  after_find :setup_statistics
  after_initialize :setup_statistics
  
  has_attached_file :xls, :path => ":rails_root/uploads/product_datasheets/:id/:basename.:extension"  
  
  validates_attachment_presence :xls
  validates_attachment_content_type :xls, :content_type => ['application/vnd.ms-excel','text/plain']
  
  scope :not_deleted, where("product_datasheets.deleted_at is NULL")
  scope :deleted, where("product_datasheets.deleted_at is NOT NULL")
  
  def path
    "#{Rails.root}/uploads/product_datasheets/#{self.id}/#{self.xls_file_name}"
  end
  
  ####################
  # Main logic of extension
  # Uses the spreadsheet to define the bounds for iteration (from first used column <inclusive> to first unused column <exclusive>)
  # Sets up statistic variables and separates the headers row from the rest of the spreadsheet
  # Iterates row-by-row to populate a hash of { :attribute => :value } pairs, uses this hash to create or update records accordingly
  ####################
  def perform
    workbook =
    begin
      Spreadsheet.open self.xls.to_file
    rescue
      puts 'Failed to open xls attachment for processing'
      return false
    end
    worksheet = workbook.worksheet(0)
    columns = [worksheet.dimensions[2], worksheet.dimensions[3]]
    header_row = worksheet.row(0)
    
    headers = []
    
    header_row.each do |key|
      if Product.column_names.include?(key) or Variant.column_names.include?(key) or key == "taxons"
        headers << key
      else
        headers << nil
      end
    end
    
    ####################
    # Creating Variants:
    #   1) First cell of headers row must define 'id' as the search key
    #   2) The headers row must define 'product_id' as an attribute to be updated
    #   3) The row containing the values must leave 'id' blank, and define a valid id for 'product_id'
    #
    # Creating Products:
    #   1) First cell of headers row must define 'id' as the search key
    #   2) The row containing the values must leave 'id' blank, and define a valid id for 'product_id'
    #
    # Updating Products:
    #   1) The search key (first cell of headers row) must be present as a column name on the Products table
    #
    # Updating Variants:
    #   1) The search key must be present as a column name on the Variants table.
    ####################
    worksheet.each(1) do |row|
      attr_hash = {}
      for i in columns[0]..columns[1]
        attr_hash[headers[i]] = row[i].to_s if row[i] and headers[i] # if there is a value and a key; .to_s is important for ARel
      end
      if headers[0] == 'id' and row[0].nil? and headers.include? 'product_id'
        create_variant(attr_hash)
      elsif headers[0] == 'id' and row[0].nil?
        create_product(attr_hash)
      elsif Product.column_names.include?(headers[0])
        update_products(headers[0], row[0], attr_hash)
      elsif Variant.column_names.include?(headers[0])
        update_variants(headers[0], row[0], attr_hash)
      else
        @queries_failed = @queries_failed + 1
      end
    end
    self.update_attribute(:processed_at, Time.now)
  end

  # [Taxon] | nil
  def get_taxons!(attr_hash)
    if attr_hash["taxons"].nil?
      return nil
    else
      taxon_names = attr_hash["taxons"].humanize.split(";").map(&:strip)
      attr_hash.delete("taxons")
      return taxon_names.map do |name|
        taxon = Taxon.where({:name => name}).first
        if taxon.nil?
          taxon = get_categories_taxonomy.root.children.build(:name => name, :taxonomy_id => get_categories_taxonomy.id,
            :permalink => (Iconv.new('US-ASCII//TRANSLIT', 'utf-8').iconv name).gsub(/[^\w]|[\_]/,' ').split.join('-').downcase)
          taxon.save
        end
        taxon
      end
    end
  end

  # Taxon
  def get_categories_taxonomy
    name = Spree::Config[:categories_taxonomy] || "Kategorie"
    taxonomy = Taxonomy.where({:name => name}).first
    if taxonomy.nil?
      taxonomy = Taxonomy.create({:name => name})
      taxonomy.root = Taxon.create({:name => name, :taxonomy_id => taxonomy.id})
      taxonomy.save
    end
    return taxonomy
  end
  
  def create_product(attr_hash)
    attr_hash["sku"] = attr_hash["sku"].split(".").first unless attr_hash["sku"].nil?
    taxons = get_taxons!(attr_hash)
    new_product = Product.new(attr_hash)
    new_product.permalink = (Iconv.new('US-ASCII//TRANSLIT', 'utf-8').iconv attr_hash["name"]).gsub(/[^\w]|[\_]/,' ').split.join('-').downcase if new_product.permalink.nil?
    new_product.taxons = taxons unless taxons.nil?
    @queries_failed = @queries_failed + 1 if not new_product.save
  end
  
  def create_variant(attr_hash)
    new_variant = Variant.new(attr_hash)
    begin
      new_variant.save
    rescue
      @queries_failed = @queries_failed + 1
    end
  end
  
  def update_products(key, value, attr_hash)
    products_to_update = Product.where(key => value).all
    @records_matched = @records_matched + products_to_update.size
    taxons = get_taxons!(attr_hash)
    products_to_update.each do |product|
      product.taxons = taxons unless taxons.nil?
      if product.save && (product.update_attributes attr_hash )
        @records_updated = @records_updated + 1
      else
        @records_failed = @records_failed + 1
      end 
    end
    @queries_failed = @queries_failed + 1 if products_to_update.size == 0
  end
  
  def update_variants(key, value, attr_hash)
    variants_to_update = Variant.where(key => value).all
    @records_matched = @records_matched + variants_to_update.size
    variants_to_update.each { |variant| 
                                        if variant.update_attributes attr_hash
                                          @records_updated = @records_updated + 1
                                        else
                                          @records_failed = @records_failed + 1
                                        end }
    @queries_failed = @queries_failed + 1 if variants_to_update.size == 0
  end
  
  def update_statistics
    self.matched_records = @records_matched
    self.failed_records = @records_failed
    self.updated_records = @records_updated
    self.failed_queries = @queries_failed
  end
  
  def setup_statistics
    @queries_failed = 0
    @records_failed = 0
    @records_matched = 0
    @records_updated = 0
  end
  
  def processed?
    !self.processed_at.nil?
  end
  
  def deleted?
    !self.deleted_at.nil?
  end
end
