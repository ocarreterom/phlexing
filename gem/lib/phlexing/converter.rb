# frozen_string_literal: true

require "nokogiri"

module Phlexing
  class Converter
    include Helpers

    using Refinements::StringRefinements

    attr_accessor :html, :custom_elements, :options, :analyzer

    def self.convert(html, **options)
      new(html, **options).component_code
    end

    def initialize(html, **options)
      @html = html
      @template_code = StringIO.new
      @custom_elements = Set.new
      @options = options
      @analyzer = RubyAnalyzer.new

      @analyzer.analyze(html)

      document = Parser.parse(html)
      handle_node(document)
    end

    def handle_text(node, level, newline: true)
      text = node.text

      if text.squish.empty? && text.length.positive?
        @template_code << indent(level)
        @template_code << whitespace(@options)

        text.strip!
      end

      if text.length.positive?
        @template_code << indent(level)

        if siblings?(node)
          @template_code << "text "
        end

        @template_code << quote(text)
        @template_code << "\n" if newline
      end
    end

    def handle_erb_element(node, level, newline: true)
      if erb_safe_output?(node)
        @template_code << "unsafe_raw "
        @template_code << node.text.from(1)
        @template_code << "\n" if newline

        return
      end

      if erb_interpolation?(node) && node.parent.children.count > 1
        if node.text.strip.start_with?("render")
          @template_code << node.text
        elsif node.text.length >= 24
          @template_code << "text("
          @template_code << node.text
          @template_code << ")"
        else
          @template_code << "text "
          @template_code << node.text
        end
      elsif erb_comment?(node)
        @template_code << "#"
        @template_code << node.text
      else
        @template_code << node.text
      end

      @template_code << "\n" if newline
    end

    def handle_element(node, level)
      @template_code << (indent(level) + node_name(node) + handle_attributes(node))

      if node.children.any?
        if node.children.one? && text_node?(node.children.first) && node.text.length <= 32
          single_line_block {
            handle_text(node.children.first, 0, newline: false)
          }
        elsif node.children.one? && erb_interpolation?(node.children.first) && node.text.length <= 32
          single_line_block {
            handle_erb_element(node.children.first, 0, newline: false)
          }
        else
          multi_line_block(level) {
            handle_children(node, level)
          }
        end
      else
        @template_code << "\n"
      end
    end

    def handle_comment_node(node, level)
      @template_code << indent(level)
      @template_code << "comment "
      @template_code << quote(node.text.strip)
      @template_code << "\n"
    end

    def handle_children(node, level)
      node.children.each do |child|
        handle_node(child, level + 1)
      end
    end

    def handle_attributes(node)
      return "" if node.attributes.keys.none?

      b = StringIO.new

      node.attributes.each_value do |attribute|
        b << attribute.name.gsub("-", "_")
        b << ": "
        b << double_quote(attribute.value)
        b << ", " if node.attributes.values.last != attribute
      end

      if node.children.any?
        "(#{b.string.strip}) "
      else
        " #{b.string.strip}"
      end
    end

    def handle_node(node, level = 0)
      case node
      when Nokogiri::XML::Text
        handle_text(node, level)
      when Nokogiri::XML::Element
        if erb_node?(node)
          handle_erb_element(node, level)
        else
          handle_element(node, level)
        end

        @template_code << "\n" if level == 1
      when Nokogiri::HTML4::DocumentFragment
        handle_children(node, level)
      when Nokogiri::XML::Comment
        handle_comment_node(node, level)
      else
        @template_code << ("UNKNOWN#{node.class}")
      end

      @template_code.string
    end

    def template_code
      Formatter.format(@template_code.string.strip)
    end

    def component_code
      OutputGenerator.new(self).generate
    end
  end
end
