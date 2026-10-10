require "../spec_helper"

# Drives Controller#page with items that count how often their details are built
class PagingProbeController < LavinMQ::HTTP::Controller
  private def register_routes
  end

  def list(context, items)
    page(context, items)
  end
end

class PagedItem
  include LavinMQ::SortableJSON
  class_property details = 0

  def initialize(@name : String, @n : Int32)
  end

  def details_tuple
    PagedItem.details += 1
    {name: @name, n: @n, nested: {n: @n}}
  end

  def sort_value(keys : Array(String))
    keys == ["n"] ? @n : super
  end
end

private def list(controller, items, query)
  PagedItem.details = 0
  io = IO::Memory.new
  context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/api/probe?#{query}"), HTTP::Server::Response.new(io))
  controller.list(context, items)
  context.response.close
  JSON.parse(HTTP::Client::Response.from_io(io.rewind).body)
end

describe LavinMQ::HTTP::Controller, "pagination" do
  items = Array.new(50) { |i| PagedItem.new("item#{i}", 50 - i) }

  it "builds the details of the requested page only" do
    with_amqp_server do |s|
      body = list(PagingProbeController.new(s), items, "page=2&page_size=10")
      body["items"].as_a.map(&.["name"]).should eq (10...20).map { |i| "item#{i}" }
      body["item_count"].should eq 10
      body["filtered_count"].should eq 50
      body["total_count"].should eq 50
      body["page_count"].should eq 5
      PagedItem.details.should eq 10
    end
  end

  it "filters before paging, building the details of the page's matches only" do
    with_amqp_server do |s|
      body = list(PagingProbeController.new(s), items, "page=1&page_size=3&name=item1")
      body["items"].as_a.map(&.["name"]).should eq ["item1", "item10", "item11"]
      body["filtered_count"].should eq 11
      body["total_count"].should eq 50
      PagedItem.details.should eq 3
    end
  end

  it "sorts on a value the item provides, building the details of the page only" do
    with_amqp_server do |s|
      body = list(PagingProbeController.new(s), items, "page=1&page_size=2&sort=n&sort_reverse=true")
      body["items"].as_a.map(&.["n"]).should eq [50, 49]
      PagedItem.details.should eq 2
    end
  end

  it "sorts on a nested detail otherwise, building the details of every item" do
    with_amqp_server do |s|
      body = list(PagingProbeController.new(s), items, "page=1&page_size=2&sort=nested.n")
      body["items"].as_a.map(&.["n"]).should eq [1, 2]
      PagedItem.details.should eq 52
    end
  end

  it "lists at most MAX_PAGE_SIZE items without a page, building no more details" do
    with_amqp_server do |s|
      max = LavinMQ::HTTP::MAX_PAGE_SIZE
      many = Array.new(max + 1) { |i| PagedItem.new("item#{i}", i) }
      body = list(PagingProbeController.new(s), many, "")
      body.as_a.size.should eq max
      PagedItem.details.should eq max
    end
  end
end
