# frozen_string_literal: true

require_relative "obj"


# CSR definition
class Csr < ArchDefObject

  # @return [Integer] CSR address (the value passed as an immediate to csrrw, etc.)
  # @return [nil] if the CSR is indirect-accesss-only
  def address
    @data["address"]
  end

  # @return [String] Least-privileged mode that can access this CSR. One of ['m', 's', 'u', 'vs', 'vu']
  def priv_mode
    @data["priv_mode"]
  end

  def long_name
    @data["long_name"]
  end

  # @return [Integer] CSR address in VS/VU mode, if different from other modes
  # @return [nil] If the CSR is not accessible in VS/VU mode, or if it's address does not change in those modes
  def virtual_address
    @data["virtual_address"]
  end

  # @return [Integer] 32 or 64, the XLEN this CSR is exclusively defined in
  # @return [nil] if this CSR is defined in all bases
  def base = @data["base"]

  # @return [Boolean] true if this CSR is defined when XLEN is 32
  def defined_in_base32? = @data["base"].nil? || @data["base"] == 32

  # @return [Boolean] true if this CSR is defined when XLEN is 64
  def defined_in_base64? = @data["base"].nil? || @data["base"] == 64

  # @return [Boolean] true if this CSR is defined regardless of the effective XLEN
  def defined_in_all_bases? = @data["base"].nil?

  # @param arch_def [ArchDef] A configuration
  # @return [Boolean] Whether or not the format of this CSR changes when the effective XLEN changes in some mode
  def format_changes_with_xlen?(arch_def)
    dynamic_length?(arch_def) ||
      implemented_fields(arch_def).any? do |f|
        f.dynamic_location?(arch_def)
      end
  end

  # @param arch_def [ImplArchDef] A configuration
  # @return [Array<Idl::FunctionDefAst>] List of functions reachable from this CSR's sw_read or a field's sw_wirte function
  def reachable_functions(arch_def)
    return @reachable_functions unless @reachable_functions.nil?

    fns = []

    if has_custom_sw_read?
      ast = pruned_sw_read_ast(arch_def)
      symtab = arch_def.sym_table.deep_clone
      symtab.push
      fns.concat(ast.reachable_functions(symtab))
    end

    if arch_def.multi_xlen?
      implemented_fields_for(arch_def, 32).each do |field|
        fns.concat(field.reachable_functions(arch_def, 32))
      end
      implemented_fields_for(arch_def, 64).each do |field|
        fns.concat(field.reachable_functions(arch_def, 64))
      end
    else
      implemented_fields_for(arch_def, arch_def.mxlen).each do |field|
        fns.concat(field.reachable_functions(arch_def, arch_def.mxlen))
      end
    end

    @reachable_functions = fns.uniq
  end

  # @param arch_def [ArchDef] Architecture definition
  # @return [Array<Idl::FunctionDefAst>] List of functions reachable from this CSR's sw_read or a field's sw_wirte function, irrespective of context
  def reachable_functions_unevaluated(arch_def)
    return @reachable_functions_unevaluated unless @reachable_functions_unevaluated.nil?

    fns = []

    if has_custom_sw_read?
      ast = sw_read_ast(arch_def.idl_compiler)
      fns.concat(ast.reachable_functions_unevaluated(arch_def))
    end

    fields.each do |field|
      fns.concat(field.reachable_functions_unevaluated(arch_def))
    end

    @reachable_functions_unevaluated = fns.uniq
  end

  # @param arch_def [ArchDef] A configuration
  # @return [Boolean] Whether or not the length of the CSR depends on a runtime value
  #                   (e.g., mstatus.SXL)
  def dynamic_length?(arch_def)
    return false if @data["length"].is_a?(Integer)

    case @data["length"]
    when "MXLEN"
      if arch_def.is_a?(ImplArchDef)
        false # mxlen can never change
      else
        if @data["base"].nil?
          # don't know MXLEN
          true
        else
          # mxlen is always "base"
          false
        end
      end
    when "SXLEN"
      if arch_def.is_a?(ImplArchDef)
        arch_def.param_values["SXLEN"] == 3264
      else
        if @data["base"].nil?
          # don't know SXLEN
          true
        else
          # sxlen is always "base"
          false
        end
      end
    when "VSXLEN"
      if arch_def.is_a?(ImplArchDef)
        arch_def.param_values["VSXLEN"] == 3264
      else
        if @data["base"].nil?
          # don't know VSXLEN
          true
        else
          # vsxlen is always "base"
          false
        end
      end
    else
      raise "Unexpected length"
    end
    # !@data["length"].is_a?(Integer) && (@data["length"] != "MXLEN")
  end

  # @param arch_def [ArchDef] A configuration (can be nil if the lenth is not dependent on a config parameter)
  # @param effective_xlen [Integer] The effective xlen, needed since some fields change location with XLEN. If the field location is not determined by XLEN, then this parameter can be nil
  # @return [Integer] Length, in bits, of the CSR
  def length(arch_def, effective_xlen = nil)
    case @data["length"]
    when "MXLEN"
      if arch_def.is_a?(ImplArchDef)
        arch_def.param_values["XLEN"]
      else
        if @data["base"].nil?
          @data["base"]
        else
          # don't know MXLEN
          raise ArgumentError, "effective_xlen is required when length is MXLEN and arch_def is generic" if effective_xlen.nil?

          effective_xlen
        end
      end
    when "SXLEN"
      if arch_def.is_a?(ImplArchDef)
        if arch_def.param_values["SXLEN"] == 3264
          raise ArgumentError, "effective_xlen is required when length is dynamic (#{name})" if effective_xlen.nil?

          effective_xlen
        else
          raise "CSR #{name} is not implemented" if arch_def.implemented_csrs.none? { |c| c.name == name }
          raise "CSR #{name} is not implemented" if arch_def.param_values["SXLEN"].nil?

          arch_def.param_values["SXLEN"]
        end
      else
        if @data["base"].nil?
          @data["base"]
        else
          # don't know SXLEN
          raise ArgumentError, "effective_xlen is required when length is SXLEN and arch_def is generic" if effective_xlen.nil?

          effective_xlen
        end
      end
    when "VSXLEN"
      if arch_def.is_a?(ImplArchDef)
        if arch_def.param_values["VSXLEN"] == 3264
          raise ArgumentError, "effective_xlen is required when length is dynamic (#{name})" if effective_xlen.nil?

          effective_xlen
        else
          raise "CSR #{name} is not implemented" if arch_def.param_values["VSXLEN"].nil?

          arch_def.param_values["VSXLEN"]
        end
      else
        if @data["base"].nil?
          @data["base"]
        else
          # don't know VSXLEN
          raise ArgumentError, "effective_xlen is required when length is VSXLEN and arch_def is generic" if effective_xlen.nil?

          effective_xlen
        end
      end
    when Integer
      @data["length"]
    else
      raise "Unexpected length field for #{csr.name}"
    end
  end

  # @return [Integer] The largest length of this CSR in any valid mode/xlen for the config
  def max_length(arch_def)
    case @data["length"]
    when "MXLEN"
      arch_def.param_values["XLEN"]
    when "SXLEN"
      if arch_def.param_values["SXLEN"] == 3264
        raise ArgumentError, "effective_xlen is required when length is dynamic (#{name})" if effective_xlen.nil?

        64
      else
        raise "CSR #{name} is not implemented" if arch_def.implemented_csrs.none? { |c| c.name == name }
        raise "CSR #{name} is not implemented" if arch_def.param_values["SXLEN"].nil?

        arch_def.param_values["SXLEN"]
      end
    when "VSXLEN"
      if arch_def.param_values["VSXLEN"] == 3264
        raise ArgumentError, "effective_xlen is required when length is dynamic (#{name})" if effective_xlen.nil?

        64
      else
        raise "CSR #{name} is not implemented" if arch_def.param_values["VSXLEN"].nil?

        arch_def.param_values["VSXLEN"]
      end
    when Integer
      @data["length"]
    else
      raise "Unexpected length field for #{csr.name}"
    end
  end

  # @return [String] IDL condition of when the effective xlen is 32
  def length_cond32
    case @data["length"]
    when "SXLEN"
      "CSR[mstatus].SXL == 0"
    when "VSXLEN"
      "CSR[hstatus].VSXL == 0"
    else
      raise "Unexpected length #{@data['length']} for #{name}"
    end
  end

  # @return [String] IDL condition of when the effective xlen is 64
  def length_cond64
    case @data["length"]
    when "SXLEN"
      "CSR[mstatus].SXL == 1"
    when "VSXLEN"
      "CSR[hstatus].VSXL == 1"
    else
      raise "Unexpected length"
    end
  end

  # @param arch_def [ArchDef] A configuration
  # @return [String] Pretty-printed length string
  def length_pretty(arch_def)
    if dynamic_length?(arch_def)
      cond = 
        case @data["length"]
        when "SXLEN"
          "CSR[mstatus].SXL == %%"
        when "VSXLEN"
          "CSR[hstatus].VSXL == %%"
        else
          raise "Unexpected length"
        end

      <<~LENGTH
        #{length(arch_def, 32)} when #{cond.sub('%%', '0')}
        #{length(arch_def, 64)} when #{cond.sub('%%', '1')}
      LENGTH
    else
      "#{length(arch_def)}-bit"
    end
  end

  # list of modes that can potentially access the field
  def modes_with_access
    case @data["priv_mode"]
    when "M"
      ["M"]
    when "S"
      ["M", "S", "VS"]
    when "U"
      ["M", "S", "U", "VS", "VU"]
    when "VS"
      ["M", "S", "VS"]
    else
      raise "unexpected priv mode"
    end
  end

  # parse description field with asciidoctor, and return the HTML result
  #
  # @return [String] Parsed description in HTML
  def description_html
    Asciidoctor.convert description
  end

  # @param arch_Def [ArchDef] A configuration
  # @return [Array<CsrField>] All implemented fields for this CSR at the given effective XLEN, sorted by location (smallest location first)
  #                           Excluded any fields that are defined by unimplemented extensions or a base that is not effective_xlen
  def implemented_fields_for(arch_def, effective_xlen)
    @implemented_fields_for ||= {}
    key = [arch_def.name, effective_xlen].hash

    return @implemented_fields_for[key] if @implemented_fields_for.key?(key)

    @implemented_fields_for[key] =
      implemented_fields(arch_def).select do |f|
        !f.key?("base") || f.base == effective_xlen
      end
  end

  # @param arch_def [ArchDef] A configuration
  # @return [Array<CsrField>] All implemented fields for this CSR
  #                           Excluded any fields that are defined by unimplemented extensions
  def implemented_fields(arch_def)
    return @implemented_fields unless @implemented_fields.nil?

    implemented_bases =
      if arch_def.param_values["SXLEN"] == 3264 ||
         arch_def.param_values["UXLEN"] == 3264 ||
         arch_def.param_values["VSXLEN"] == 3264 ||
         arch_def.param_values["VUXLEN"] == 3264
        [32, 64]
      else
        [arch_def.param_values["XLEN"]]
      end

    @implemented_fields = fields.select do |f|
      f.exists_in_cfg?(implemented_bases, arch_def.implemented_extensions)
    end
  end

  # @return [Array<CsrField>] All known fields of this CSR
  def fields
    return @fields unless @fields.nil?

    @fields = @data["fields"].map { |_field_name, field_data| CsrField.new(self, field_data) }
  end

  # @return [Array<CsrField>] All known fields of this CSR when XLEN == +effective_xlen+
  # equivalent to {#fields} if +effective_xlen+ is nil
  def fields_for(effective_xlen)
    fields.select { |f| effective_xlen.nil? || !f.key?("base") || f.base == effective_xlen }
  end

  # @return [Hash<String,CsrField>] Hash of fields, indexed by field name
  def field_hash
    @field_hash unless @field_hash.nil?

    @field_hash = {}
    fields.each do |field|
      @field_hash[field.name] = field
    end

    @field_hash
  end

  # @return [Boolean] true if a field named 'field_name' is defined in the csr, and false otherwise
  def field?(field_name)
    field_hash.key?(field_name.to_s)
  end

  # returns [CsrField,nil] field named 'field_name' if it exists, and nil otherwise
  def field(field_name)
    field_hash[field_name.to_s]
  end

  # @param arch_def [ArchDef] A configuration
  # @param effective_xlen [Integer] The effective XLEN to apply, needed when field locations change with XLEN in some mode
  # @return [Idl::BitfieldType] A bitfield type that can represent all fields of the CSR
  def bitfield_type(arch_def, effective_xlen = nil)
    Idl::BitfieldType.new(
      "Csr#{name.capitalize}Bitfield",
      length(arch_def, effective_xlen),
      fields_for(effective_xlen).map(&:name),
      fields_for(effective_xlen).map { |f| f.location(arch_def, effective_xlen) }
    )
  end

  # @return [Boolean] true if the CSR has a custom sw_read function
  def has_custom_sw_read?
    @data.key?("sw_read()") && !@data["sw_read()"].empty?
  end

  # @return [FunctionBodyAst] The abstract syntax tree of the sw_read() function, after being type checked
  # @param arch_def [ImplArchDef] A configuration
  def type_checked_sw_read_ast(arch_def)
    @type_checked_sw_read_asts ||= {}
    ast = @type_checked_sw_read_asts[arch_def.name]
    return ast unless ast.nil?

    symtab = arch_def.sym_table.deep_clone
    symtab.push
    # all CSR instructions are 32-bit
    symtab.add(
      "__instruction_encoding_size",
      Idl::Var.new("__instruction_encoding_size", Idl::Type.new(:bits, width: 6), 32)
    )
    symtab.add(
      "__expected_return_type",
      Idl::Type.new(:bits, width: 128)
     )

    ast = sw_read_ast(arch_def.idl_compiler)
    arch_def.idl_compiler.type_check(
      ast,
      symtab,
      "CSR[#{name}].sw_read()"
    )
    @type_checked_sw_read_asts[arch_def.name] = ast
  end

  # @return [FunctionBodyAst] The abstract syntax tree of the sw_read() function
  # @param idl_compiler [Idl::Compiler] A compiler
  def sw_read_ast(idl_compiler)
    return @sw_read_ast unless @sw_read_ast.nil?
    return nil if @data["sw_read()"].nil?

    # now, parse the function
    @sw_read_ast = idl_compiler.compile_func_body(
      @data["sw_read()"],
      return_type: Idl::Type.new(:bits, width: 128), # big int to hold special return values
      name: "CSR[#{name}].sw_read()",
      input_file: source_line("sw_read()"),
      type_check: false
    )

    raise "unexpected #{@sw_read_ast.class}" unless @sw_read_ast.is_a?(Idl::FunctionBodyAst)

    @sw_read_ast
  end

  def pruned_sw_read_ast(arch_def)
    @pruned_sw_read_asts ||= {}
    ast = @pruned_sw_read_asts[arch_def.name]
    return ast unless ast.nil?

    ast = type_checked_sw_read_ast(arch_def).prune(arch_def.sym_table.deep_clone)

    symtab = arch_def.sym_table.deep_clone
    symtab.push
    # all CSR instructions are 32-bit
    symtab.add(
      "__instruction_encoding_size",
      Idl::Var.new("__instruction_encoding_size", Idl::Type.new(:bits, width: 6), 32)
    )
    symtab.add(
      "__expected_return_type",
      Idl::Type.new(:bits, width: 128)
    )

    arch_def.idl_compiler.type_check(
      ast,
      symtab,
      "CSR[#{name}].sw_read()"
    )
    @pruned_sw_read_asts[arch_def.name] = ast
  end

  # @example Result for an I-type instruction
  #   {reg: [
  #     {bits: 7,  name: 'OP-IMM',    attr: ['{op_major_name}'], type: 8},
  #     {bits: 5,  name: 'rd',        attr: [''], type: 2},
  #     {bits: 3,  name: {funct3},    attr: ['{mnemonic}'], type: 8},
  #     {bits: 5,  name: 'rs1',       attr: [''], type: 4},
  #     {bits: 12, name: 'imm12',     attr: [''], type: 6}
  #   ]}
  #
  # @param arch_def [ArchDef] A configuration
  # @param effective_xlen [Integer,nil] Effective XLEN to use when CSR length is dynamic
  # @return [Hash] A representation of the WaveDrom drawing for the CSR (should be turned into JSON for wavedrom)
  def wavedrom_desc(arch_def, effective_xlen)
    desc = {
      "reg" => []
    }
    last_idx = -1
    field_list =
      if arch_def.is_a?(ImplArchDef)
        implemented_fields_for(arch_def, effective_xlen)
      else
        fields
      end
    field_list.each do |field|

      if field.location(arch_def, effective_xlen).min != last_idx + 1
        # have some reserved space
        desc["reg"] << { "bits" => (field.location(arch_def, effective_xlen).min - last_idx - 1), type: 1 }
      end
      desc["reg"] << { "bits" => field.location(arch_def, effective_xlen).size, "name" => field.name, type: 2 }
      last_idx = field.location(arch_def, effective_xlen).max
    end
    if !field_list.empty? && (field_list.last.location(arch_def, effective_xlen).max != (length(arch_def, effective_xlen) - 1))
      # reserved space at the end
      desc["reg"] << { "bits" => (length(arch_def, effective_xlen) - 1 - last_idx), type: 1 }
      # desc['reg'] << { 'bits' => 1, type: 1 }
    end
    desc["config"] = { "bits" => length(arch_def, effective_xlen) }
    desc["config"]["lanes"] = length(arch_def, effective_xlen) / 16
    desc
  end

  # @param possible_xlens [Array<Integer>] List of xlens that be used in any implemented mode
  # @param extensions [Array<ExtensionVersion>] List of extensions implemented
  # @return [Boolean] whether or not the instruction is implemented given the supplies config options
  def exists_in_cfg?(possible_xlens, extensions)
    (@data["base"].nil? || (possible_xlens.include? @data["base"])) &&
      extensions.any? { |e| defined_by?(e) }
  end
end
