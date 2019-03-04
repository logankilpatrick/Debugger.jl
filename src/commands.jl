function perform_return!(state::DebuggerState)
    returning_frame = state.stack[end]
    returning_expr = pc_expr(returning_frame)
    @assert isexpr(returning_expr, :return)
    val = @lookup(returning_frame, returning_expr.args[1])
    if length(state.stack) != 1
        calling_frame = state.stack[end-1]
        if returning_frame.code.generator
            # Don't do anything here, just return us to where we were
        else
            prev = pc_expr(calling_frame)
            if isexpr(prev, :(=))
                do_assignment!(calling_frame, prev.args[1], val)
            elseif isassign(calling_frame)
                do_assignment!(calling_frame, getlhs(calling_frame.pc[]), val)
            end
            state.stack[end-1] = JuliaStackFrame(calling_frame, maybe_next_call!(Compiled(), calling_frame,
                calling_frame.pc[] + 1))
        end
    else
        @assert !returning_frame.code.generator
        state.overall_result = val
    end
    pop!(state.stack)
    if !isempty(state.stack) && state.stack[end].code.wrapper
        state.stack[end] = JuliaStackFrame(state.stack[end], finish!(Compiled(), state.stack[end]))
        perform_return!(state)
    end
end

function propagate_exception!(state::DebuggerState, exc)
    while !isempty(state.stack)
        pop!(state.stack)
        isempty(state.stack) && break
        if isa(state.stack[end], JuliaStackFrame)
            if !isempty(state.stack[end].exception_frames)
                # Exception caught
                state.stack[end] = JuliaStackFrame(state.stack[end],
                    JuliaProgramCounter(state.stack[end].exception_frames[end]))
                state.stack[end].last_exception[] = exc
                return true
            end
        end
    end
    rethrow(exc)
end

function execute_command(state::DebuggerState, frame::JuliaStackFrame, ::Union{Val{:nc},Val{:n},Val{:se}}, cmd::AbstractString)
    pc = try
        cmd == "nc" ? next_call!(Compiled(), frame) :
        cmd == "n" ? next_line!(Compiled(), frame, state.stack) :
        #= cmd == "se" =# step_expr!(Compiled(), frame)
    catch err
        propagate_exception!(state, err)
        state.stack[end] = JuliaStackFrame(state.stack[end], next_call!(Compiled(), state.stack[end], state.stack[end].pc[]))
        return true
    end
    if pc != nothing
        state.stack[end] = JuliaStackFrame(state.stack[end], pc)
        return true
    end
    perform_return!(state)
    return true
end

function execute_command(state::DebuggerState, frame, cmd::Union{Val{:s},Val{:si},Val{:sg}}, command::AbstractString)
    pc = frame.pc[]
    first = true
    while true
        expr = pc_expr(frame, pc)
        if isa(expr, Expr)
            if is_call(expr)
                isexpr(expr, :(=)) && (expr = expr.args[2])
                args = map(x->isa(x, QuoteNode) ? x.value : @lookup(frame, x), expr.args)
                expr = Expr(:call, args...)
                f = (expr.args[1] == Core._apply) ? expr.args[2] : expr.args[1]
                ok = true
                new_frame = enter_call_expr(expr; enter_generated = command == "sg")
                if new_frame != nothing
                    if (cmd == Val{:s}() || cmd == Val{:sg}())
                        new_frame = JuliaStackFrame(new_frame, maybe_next_call!(Compiled(), new_frame))
                    end
                    # Don't step into Core.Compiler
                    if moduleof(new_frame) == Core.Compiler
                        ok = false
                    else
                        state.stack[end] = JuliaStackFrame(frame, pc)
                        push!(state.stack, new_frame)
                        return true
                    end
                else
                    ok = false
                end
                if !ok
                    # It's confusing if we step into the next call, so just go there
                    # and then return
                    state.stack[end] = JuliaStackFrame(frame, next_call!(Compiled(), frame, pc))
                    return true
                end
            elseif !first && isexpr(expr, :return)
                state.stack[end] = JuliaStackFrame(frame, pc)
                return true
            end
        end
        first = false
        command == "si" && break
        new_pc = try
            _step_expr!(Compiled(), frame, pc)
        catch err
            propagate_exception!(state, err)
            state.stack[end] = JuliaStackFrame(state.stack[end], next_call!(Compiled(), state.stack[end], pc))
            return true
        end
        if new_pc == nothing
            state.stack[end] = JuliaStackFrame(frame, pc)
            perform_return!(state)
            return true
        else
            pc = new_pc
        end
    end
    state.stack[end] = JuliaStackFrame(frame, pc)
    return true
end

function execute_command(state::DebuggerState, frame::JuliaStackFrame, ::Val{:finish}, cmd::AbstractString)
    state.stack[end] = JuliaStackFrame(frame, finish!(Compiled(), frame))
    perform_return!(state)
    return true
end

"""
    Runs code_typed on the call we're about to run
"""
function execute_command(state::DebuggerState, frame::JuliaStackFrame, ::Val{:code_typed}, cmd::AbstractString)
    expr = pc_expr(frame, frame.pc[])
    if isa(expr, Expr)
        if is_call(expr)
            isexpr(expr, :(=)) && (expr = expr.args[2])
            args = map(x->isa(x, QuoteNode) ? x.value : @lookup(frame, x), expr.args)
            f = args[1]
            if f == Core._apply
                f = to_function(args[2])
                args = Base.append_any((args[2],), args[3:end]...)
            end
            if isa(args[1], Core.Builtin)
                return false
            end
            ct = Base.code_typed(f, Base.typesof(args[2:end]...))
            ct = ct == 1 ? ct[1] : ct
            println(ct)
        end
    end
    return false
end


function execute_command(state::DebuggerState, frame::JuliaStackFrame, ::Val{:?}, cmd::AbstractString)
    display(
            @md_str """
    Basic Commands:\\
    - `n` steps to the next line\\
    - `s` steps into the next call\\
    - `finish` runs to the end of the function\\
    - `bt` shows a simple backtrace\\
    - ``` `stuff ``` runs `stuff` in the current frame's context\\
    - `fr v` will show all variables in the current frame\\
    - `f n` where `n` is an integer, will go to the `n`-th frame\\
    - `q` quits the debugger, returning `nothing`\\
    Advanced commands:\\
    - `nc` steps to the next call\\
    - `se` does one expression step\\
    - `si` does the same but steps into a call if a call is the next expression\\
    - `sg` steps into a generated function\\
    """)
    return false
end