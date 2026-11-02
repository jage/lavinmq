module LavinMQ
  module Debug
    # Unwinds a parked fiber's stack from the context `Fiber.swapcontext` saved, using the
    # binary's DWARF call frame information (`.eh_frame`), as release builds have no frame
    # pointers. Only reads memory within the fiber's stack.
    module Unwind
      MAX_FRAMES = 64

      {% if flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64)) %}
        SUPPORTED = true
      {% else %}
        SUPPORTED = false
        alias Cache = Hash(UInt64, Nil)
      {% end %}

      # Return addresses of a parked fiber's frames, innermost first. Empty if the fiber
      # isn't parked, or on unsupported platforms. Best effort: a fiber resumed on another
      # thread while it's being read can give a truncated or bogus trace, never a crash.
      #
      # Pass the same *cache* for many fibers: they mostly share call sites.
      def self.backtrace(fiber : Fiber, cache : Cache = Cache.new, max = MAX_FRAMES) : Array(Void*)
        ips = Array(Void*).new
        {% if flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64)) %}
          return ips if fiber.running? || fiber.dead? || fiber.same?(Fiber.current)
          stack = fiber.@stack
          top = fiber.@context.stack_top
          Walker.new(top, stack.bottom, cache).walk(max) { |ip| ips << ip }
          # The fiber ran meanwhile: the frames may be from different points in time
          ips.clear unless fiber.resumable? && fiber.@context.stack_top == top
        {% end %}
        ips
      end

      # Symbolized frames, e.g. "src/lavinmq/amqp/client.cr:200:7 in 'read_loop'"
      def self.symbolize(ips : Array(Void*)) : Array(String)
        Exception::CallStack.load_debug_info
        ips.map { |ip| Exception::CallStack.decode_backtrace_frame(ip, false) || "0x#{ip.address.to_s(16)}" }
      end

      {% if flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64)) %}
        lib LibGccUnwind
          struct DwarfEhBases
            tbase : Void*
            dbase : Void*
            func : Void*
          end

          fun find_fde = _Unwind_Find_FDE(pc : Void*, bases : DwarfEhBases*) : UInt8*
        end

        {% if flag?(:x86_64) %}
          SP_REG = 7_u64
          FP_REG = 6_u64
          RA_REG = 16_u64
        {% else %}
          SP_REG = 31_u64
          FP_REG = 29_u64
          RA_REG = 30_u64
        {% end %}

        # How a register of the caller is recovered
        enum RuleKind : UInt8
          SameValue # unchanged, or undefined
          Offset    # saved at CFA + offset
          ValOffset # value is CFA + offset
        end

        record Rule, kind : RuleKind = RuleKind::SameValue, offset : Int64 = 0

        struct Rules
          property cfa_reg : UInt64 = SP_REG
          property cfa_offset : Int64 = 0
          property? cfa_ok = true
          property fp = Rule.new
          property ra = Rule.new

          def initialize
          end
        end

        class UnsupportedCFI < Exception; end

        struct Cursor
          getter pos : UInt8*

          def initialize(@pos : UInt8*, @end : UInt8*)
          end

          def at_end? : Bool
            @pos >= @end
          end

          def u8 : UInt8
            check(1)
            v = @pos.value
            @pos += 1
            v
          end

          def u16 : UInt16
            check(2)
            v = @pos.as(UInt16*).value
            @pos += 2
            v
          end

          def u32 : UInt32
            check(4)
            v = @pos.as(UInt32*).value
            @pos += 4
            v
          end

          def uleb : UInt64
            result = 0_u64
            shift = 0
            loop do
              b = u8
              result |= (b & 0x7f).to_u64 << shift if shift < 64
              shift += 7
              return result if b & 0x80 == 0
            end
          end

          def sleb : Int64
            result = 0_i64
            shift = 0
            loop do
              b = u8
              result |= (b & 0x7f).to_i64 << shift if shift < 64
              shift += 7
              if b & 0x80 == 0
                result |= -1_i64 << shift if shift < 64 && b & 0x40 != 0
                return result
              end
            end
          end

          def cstring : String
            start = @pos
            while u8 != 0
            end
            String.new(start, @pos - start - 1)
          end

          def skip(n : UInt64) : Nil
            check(n)
            @pos += n
          end

          # Skips a pointer in the given DW_EH_PE encoding
          def skip_encoded(encoding : UInt8) : Nil
            return if encoding == 0xff # omitted
            case encoding & 0x0f
            when 0x00, 0x04, 0x0c then skip(8)
            when 0x02, 0x0a       then skip(2)
            when 0x03, 0x0b       then skip(4)
            when 0x01             then uleb
            when 0x09             then sleb
            else                       raise UnsupportedCFI.new("pointer encoding #{encoding}")
            end
          end

          private def check(n)
            raise UnsupportedCFI.new("truncated") if @pos + n > @end
          end
        end

        # A CIE or FDE: the entry's contents after the length field
        protected def self.entry(ptr : UInt8*) : {UInt8*, UInt8*}
          len = ptr.as(UInt32*).value.to_u64
          ptr += 4
          if len == 0xffffffff_u64
            len = ptr.as(UInt64*).value
            ptr += 8
          end
          {ptr, ptr + len}
        end

        struct CIE
          getter code_align : UInt64
          getter data_align : Int64
          getter fde_encoding : UInt8
          getter? augmented : Bool
          getter instructions : UInt8*
          getter instructions_end : UInt8*

          def initialize(ptr : UInt8*)
            start, stop = Unwind.entry(ptr)
            c = Cursor.new(start, stop)
            c.u32 # CIE id
            version = c.u8
            aug = c.cstring
            @code_align = c.uleb
            @data_align = c.sleb
            version == 1 ? c.u8 : c.uleb # return address register
            @fde_encoding = 0_u8
            @augmented = aug.starts_with?('z')
            if @augmented
              aug_len = c.uleb
              aug_end = c.pos + aug_len
              aug.each_char.skip(1).each do |ch|
                case ch
                when 'R' then @fde_encoding = c.u8
                when 'P' then c.skip_encoded(c.u8)
                when 'L' then c.u8
                when 'S', 'B', 'G'
                else raise UnsupportedCFI.new("augmentation #{aug}")
                end
              end
              c = Cursor.new(aug_end, stop)
            end
            @instructions = c.pos
            @instructions_end = stop
          end
        end

        # Unwind rules by return address, nil where there's no usable frame information
        alias Cache = Hash(UInt64, Rules?)

        struct Walker
          def initialize(@top : Void*, @bottom : Void*, @cache : Cache)
          end

          private def read(addr : UInt64) : UInt64?
            return nil if addr < @top.address || addr + 8 > @bottom.address || addr % 8 != 0
            Pointer(UInt64).new(addr).value
          end

          def walk(max : Int32, & : Void* ->) : Nil
            top = @top.as(UInt64*)
            {% if flag?(:x86_64) %}
              # swapcontext pushed rdi, rbx, rbp, r12-r15 below the return address
              fp = top[4]
              pc = top[7]
              sp = @top.address + 8 * 8
            {% else %}
              # swapcontext stored 22 words: d8-d15, lr, fp, x19-x28, x0 + padding
              pc = top[8]
              fp = top[9]
              sp = @top.address + 22 * 8
            {% end %}
            max.times do
              break if pc == 0
              yield Pointer(Void).new(pc)
              next_frame = step(pc, sp, fp) || break
              pc, sp, fp = next_frame
            end
          rescue UnsupportedCFI
          end

          # Registers of the caller frame: {pc, sp, fp}
          private def step(pc : UInt64, sp : UInt64, fp : UInt64) : {UInt64, UInt64, UInt64}?
            rules = @cache.fetch(pc) { @cache[pc] = Unwind.rules_for(pc) } || return
            base = case rules.cfa_reg
                   when SP_REG then sp
                   when FP_REG then fp
                   else             return
                   end
            cfa = base &+ rules.cfa_offset
            return if cfa <= sp || cfa > @bottom.address
            ra = recover(rules.ra, cfa, 0_u64) || return
            new_fp = recover(rules.fp, cfa, fp) || return
            {ra, cfa, new_fp}
          end

          private def recover(rule : Rule, cfa : UInt64, current : UInt64) : UInt64?
            case rule.kind
            in .same_value? then current
            in .offset?     then read(cfa &+ rule.offset)
            in .val_offset? then cfa &+ rule.offset
            end
          end
        end

        protected def self.rules_for(pc : UInt64) : Rules?
          bases = uninitialized LibGccUnwind::DwarfEhBases
          # pc is a return address, look up the call instruction before it
          fde = LibGccUnwind.find_fde(Pointer(Void).new(pc - 1), pointerof(bases))
          return if fde.null?
          rules = rules_at(fde, bases.func.address, pc - 1)
          rules if rules.cfa_ok?
        rescue UnsupportedCFI
        end

        # Runs the CIE's and the FDE's instructions up to *target*
        protected def self.rules_at(fde : UInt8*, func_start : UInt64, target : UInt64) : Rules
          start, stop = entry(fde)
          cie_ptr = start - start.as(UInt32*).value # CIE pointer is relative to its own field
          cie = CIE.new(cie_ptr)
          c = Cursor.new(start + 4, stop)
          c.skip_encoded(cie.fde_encoding)        # pc_begin, _Unwind_Find_FDE decoded it
          c.skip_encoded(cie.fde_encoding & 0x0f) # pc_range, never pc-relative
          c.skip(c.uleb) if cie.augmented?
          initial = Rules.new
          initial = execute(Cursor.new(cie.instructions, cie.instructions_end), cie, initial, initial, UInt64::MAX, func_start)
          execute(c, cie, initial, initial, target, func_start)
        end

        private def self.execute(c : Cursor, cie : CIE, rules : Rules, initial : Rules, target : UInt64, loc : UInt64) : Rules
          saved = StaticArray(Rules, 8).new(Rules.new)
          depth = 0
          until c.at_end?
            op = c.u8
            arg = (op & 0x3f).to_u64
            case op & 0xc0
            when 0x40 # advance_loc
              loc += arg * cie.code_align
              return rules if loc > target
              next
            when 0x80 # offset
              rules = set_rule(rules, arg, Rule.new(:offset, c.uleb.to_i64 * cie.data_align))
              next
            when 0xc0 # restore
              rules = restore(rules, initial, arg)
              next
            end
            case op
            when 0x00 # nop
            when 0x01 then raise UnsupportedCFI.new("set_loc")
            when 0x02, 0x03, 0x04 # advance_loc1/2/4
              delta = op == 0x02 ? c.u8.to_u64 : (op == 0x03 ? c.u16.to_u64 : c.u32.to_u64)
              loc += delta * cie.code_align
              return rules if loc > target
            when 0x05 # offset_extended
              reg = c.uleb
              rules = set_rule(rules, reg, Rule.new(:offset, c.uleb.to_i64 * cie.data_align))
            when 0x06 then rules = restore(rules, initial, c.uleb)
            when 0x07, 0x08 then rules = set_rule(rules, c.uleb, Rule.new) # undefined, same_value
            when 0x09 # register: saved in another register, not tracked
              reg = c.uleb
              c.uleb
              rules.cfa_ok = false if reg == RA_REG || reg == FP_REG
            when 0x0a # remember_state
              raise UnsupportedCFI.new("state stack") if depth >= saved.size
              saved[depth] = rules
              depth += 1
            when 0x0b # restore_state
              raise UnsupportedCFI.new("state stack") if depth == 0
              depth -= 1
              rules = saved[depth]
            when 0x0c # def_cfa
              rules.cfa_reg = c.uleb
              rules.cfa_offset = c.uleb.to_i64
            when 0x0d then rules.cfa_reg = c.uleb
            when 0x0e then rules.cfa_offset = c.uleb.to_i64
            when 0x0f # def_cfa_expression
              c.skip(c.uleb)
              rules.cfa_ok = false
            when 0x10 # expression
              reg = c.uleb
              c.skip(c.uleb)
              rules.cfa_ok = false if reg == RA_REG || reg == FP_REG
            when 0x11 # offset_extended_sf
              reg = c.uleb
              rules = set_rule(rules, reg, Rule.new(:offset, c.sleb * cie.data_align))
            when 0x12 # def_cfa_sf
              rules.cfa_reg = c.uleb
              rules.cfa_offset = c.sleb * cie.data_align
            when 0x13 then rules.cfa_offset = c.sleb * cie.data_align
            when 0x14 # val_offset
              reg = c.uleb
              rules = set_rule(rules, reg, Rule.new(:val_offset, c.uleb.to_i64 * cie.data_align))
            when 0x15 # val_offset_sf
              reg = c.uleb
              rules = set_rule(rules, reg, Rule.new(:val_offset, c.sleb * cie.data_align))
            when 0x16 # val_expression
              reg = c.uleb
              c.skip(c.uleb)
              rules.cfa_ok = false if reg == RA_REG || reg == FP_REG
            when 0x2d # AArch64 negate_ra_state (return address signing)
              rules.cfa_ok = false
            when 0x2e then c.uleb # GNU_args_size
            when 0x2f # GNU_negative_offset_extended
              reg = c.uleb
              rules = set_rule(rules, reg, Rule.new(:offset, -(c.uleb.to_i64 * cie.data_align)))
            else
              raise UnsupportedCFI.new("opcode #{op}")
            end
          end
          rules
        end

        private def self.set_rule(rules : Rules, reg : UInt64, rule : Rule) : Rules
          case reg
          when RA_REG then rules.ra = rule
          when FP_REG then rules.fp = rule
          end
          rules
        end

        private def self.restore(rules : Rules, initial : Rules, reg : UInt64) : Rules
          case reg
          when RA_REG then rules.ra = initial.ra
          when FP_REG then rules.fp = initial.fp
          end
          rules
        end
      {% end %}
    end
  end
end
