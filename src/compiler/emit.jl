# Stacks

mutable struct Stack{T}
  idx::Int
  data::Vector{T}
end

Stack(data::Vector{T}) where T =
  Stack{T}(length(data), data)

function Base.pop!(stk::Stack)
  i = stk.idx
  stk.idx = i == 1 ? length(stk.data) : i-1
  @inbounds return stk.data[i]
end

xstack(T) = (Vector{T}, Expr(:call, Vector{T}))

function _push!(a::Vector{T}, x::T) where T
  Base._growend!(a, 1)
  @inbounds a[end] = x
  return
end

# Emit

function alphauses(ir, bi)
  us = []
  for i = range(ir.cfg.blocks[bi]), u in userefs(ir.stmts[i])
    u[] isa Alpha && push!(us, SSAValue(u[].id))
  end
  return unique(us)
end

xtuple(xs...) = xcall(:tuple, xs...)

concrete(T::DataType) = T
concrete(::Type{Type{T}}) where T = typeof(T)

# TODO: combine stacks by type
function forward_stacks!(adj, F)
  stks, recs = [], []
  for fb = 1:length(adj.perm)
    for α in alphauses(adj.back, invperm(adj.perm)[fb])
      if fb == 1
        push!(recs, α)
      else
        T = exprtype(adj.forw, α)
        stk = insert_node!(adj.forw, 1, xstack(T)...)
        push!(recs, stk)
        insert_blockend!(adj.forw, blockidx(adj.forw, α.id), Any, xcall(Zygote, :_push!, stk, α))
      end
      push!(stks, (invperm(adj.perm)[fb], alpha(α)))
    end
  end
  args = [Argument(i) for i = 3:length(adj.forw.argtypes)]
  T = Tuple{concrete.(exprtype.(Ref(adj.forw), (args..., recs...)))...}
  isconcretetype(T) || (T = Any)
  rec = insert_node!(adj.forw, length(adj.forw.stmts), T,
                     xtuple(args..., recs...))
  if usetyped
    rec = insert_node!(adj.forw, length(adj.forw.stmts), J{F,T},
                       Expr(:call, J{F,T}, rec))
  else
    rec = insert_node!(adj.forw, length(adj.forw.stmts), Any,
                       Expr(:call, J{F}, rec))
  end
  ret = xtuple(adj.forw.stmts[end].val, rec)
  R = exprtype(adj.forw, adj.forw.stmts[end].val)
  ret = insert_node!(adj.forw, length(adj.forw.stmts), Tuple{R,J{F,T}}, ret)
  adj.forw.stmts[end] = ReturnNode(ret)
  forw = compact!(adj.forw)
  return forw, stks
end

function reverse_stacks!(adj, stks, nargs)
  ir = adj.back
  t = insert_node!(ir, 1, Any, xcall(Base, :getfield, Argument(1), QuoteNode(:t)))
  for b = 1:length(ir.cfg.blocks)
    repl = Dict()
    for (i, (b′, α)) in enumerate(stks)
      b == b′ || continue
      loc = max(2,afterphi(ir, range(ir.cfg.blocks[b])[1]))
      if adj.perm[b′] == 1
        val = insert_node!(ir, loc, Any, xcall(:getindex, t, i+nargs))
      else
        stk = insert_node!(ir, 1, Any, xcall(:getindex, t, i+nargs))
        stk = insert_node!(ir, 1, Any, xcall(Zygote, :Stack, stk))
        val = insert_node!(ir, loc, Any, xcall(:pop!, stk))
      end
      repl[α] = val
    end
    for i in range(ir.cfg.blocks[b]), u in userefs(ir.stmts[i])
      if u.stmt == Expr(:call, :Δ)
        u.stmt = Argument(2)
      elseif u[] isa Argument
        x = insert_node!(ir, i, Any, xcall(:getindex, t, u[].n-2))
        u[] = x
      elseif haskey(repl, u[])
        u[] = repl[u[]]
      else continue
      end
      ir.stmts[i] = u.stmt
    end
  end
  return compact!(ir)
end

function stacks!(adj, T)
  forw, stks = forward_stacks!(adj, T)
  back = reverse_stacks!(adj, stks, length(forw.argtypes)-2)
  return forw, back
end

varargs(m::Method, n) = m.isva ? n - m.nargs + 1 : nothing

function _lookup_grad(T)
  (m = meta(T)) == nothing && return
  usetyped && m.ret == Union{} && return
  va = varargs(m.method, length(T.parameters))
  forw, back = stacks!(Adjoint(IRCode(m), varargs = va), T)
  # verify_ir(forw)
  # verify_ir(back)
  m, forw, back
end
