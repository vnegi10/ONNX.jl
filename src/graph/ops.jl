  using Base
# TODO: we need kwarg support for many of these

# Generic
get_tuple(x) = (x...,)
get_tuple() = nothing
convert_type(x) = Base.convert(Array{Float32, 1}, x)

ops[:Concat] = function (params, xs...)
  vcall(:cat, params[:axis] + 2, xs...)
end

ops[:Gemm] = function (params, A, B, C)
  @assert haskey(params, :alpha) && haskey(params, :beta)
  layer = DataFlow.isconstant(B)
  A = get(params, :transA, 0) == 1 ? vcall(:transpose, A) : A
  B = get(params, :transB, 0) == 1 ? vcall(:transpose, B) : B
  layer ?
    vcall(vcall(:Dense, B, C), vcall(:vec, A)) :
    vcall(:broadcast, :+, vcall(*, B, A), C)
end

# Image

function pads(ps)
  padbegin = ps[1:end÷2]
  padend   = ps[end÷2+1:end]
  if (padbegin != padend)
    println("WARNING: RESHAPING PADS DUE TO ASYMMETRIC PADDING")
    ele = Int64(sum(ps) / 4)
    padbegin = (ele, ele)
    return padbegin
  end
  return (padbegin...)
end

ops[:Conv] = function (params, x, w, b...)
  if !haskey(params, Symbol("pads"))
    params[:pads] = [0,0,0,0]
  end
  if !haskey(params, Symbol("strides"))
    params[:strides] = (1,1)
  end
  if (haskey(params, Symbol("auto_pad")))
    if (String(params[:auto_pad]) == "SAME_UPPER" || String(params[:auto_pad] == "SAME_LOWER"))
      params[:pads] =  Base.convert(Array{Int64,1}, (params[:kernel_shape] .- 1)./2) # Only for strides = [1,1]
    end                                                                           # To Do: Add support for other stride values.
  end
  if isempty(b)
    return vcall(vcall(:Conv, w, convert_type([0]), :relu, Symbol("stride=$((params[:strides]...,))"), Symbol("pad=$(pads(params[:pads]))")), x)
  end
  vcall(vcall(:Conv, w, b[1], Symbol("stride=$((params[:strides]...,))"),Symbol("pad=$(pads(params[:pads]))")), x)
end

ops[:MaxPool] = function (params, x)
  if !(haskey(params, :strides))
    params[:strides] = [1,1]
  end
  if !(haskey(params, :pads))
    params[:pads] = [0,0,0,0]
  end
  strides = params[:strides] == params[:kernel_shape] ? [] : [params[:strides]]
  length(params[:pads]) == 4 ?
  vcall(:maxpool, x, (params[:kernel_shape]...,), Symbol("pad=$(pads(params[:pads]))"),Symbol("stride=$((params[:strides]...))")) :
  vcall(:maxpool, x, (params[:kernel_shape]...,), Symbol("pad=$(params[:pads]...)"),Symbol("stride=$((params[:strides]...))"))
end

ops[:GlobalAveragePool] = function (params, x)
  vcall(:mean, x, (1,2))
end

ops[:AveragePool] = function (params, x)
  length(params[:kernel_shape]) == 2 || error("Only maxpool2d currently supported")
  strides = params[:strides] == params[:kernel_shape] ? [] : [params[:strides]]
  if !haskey(params, :pads)
    params[:pads] = [0,0,0,0]
  end
  vcall(:meanpool, x ,(params[:kernel_shape]...), Symbol("pad=$(pads(params[:pads]))"),Symbol("stride=$((params[:strides]...))"))
end

ops[:BatchNormalization] = function (params, x, scale, b, mean, var)
  if !haskey(params ,Symbol("momentum"))
    params[:momentum] = 0.9
  end
  vcall(vcall(:BatchNorm, vcall(:getindex, vcall(:size, x), 3), Symbol("ϵ=$(params[:epsilon])"),Symbol("momentum=$(params[:momentum])")), x)
end

# Regularise

ops[:Dropout] = function (params, x)
  vcall(vcall(:Dropout, params[:ratio]), x)
end

# Activation

iscallp(f, v) = DataFlow.iscall(v) && f(v[1])
islayer(v, name) = iscallp(l -> iscallp(x -> x == constant(name), l), v)

ops[:Identity] = function(params, x)
  vcall(:identity, x)
end

ops[:Flatten] = function(params, x)
  prod1 = vcall(:*, vcall(:size, x)[1:params[:axis]])
  prod2 = vcall(:*, vcall(:size, x)[params[:axis +1]:end])
  vcall(:reshape, x, prod1, prod2)
end

ops[:Relu] = function (params, x)
 # if islayer(x, :Conv) || islayer(x, :Dense)
 #   layer = x[1]
 #   layer = vcall(layer[1], layer[2:3]..., :relu, layer[end], layer[4])
 #   vcall(layer, x[2])
 # else
    vcall(broadcast, :relu, x)
  #end
end

ops[:LeakyRelu] = function(params, x)
  if !haskey(params, :alpha)
    params[:alpha] = 0.01
  end
  vcall(:leakyrelu, x, params[:alpha])
end

ops[:Sigmoid] = function (params, x)
  vcall(:sigmoid, x)
end

ops[:Softmax] = function (params, x)
  vcall(:softmax, vcall(:vec, x))
end

ops[:Floor] = function (params, x)
  vcall(:broadcast, :floor, x)
end

ops[:Exp] = function(params, x)
  vcall(:broadcast, :exp, x)
end

ops[:Log] = function(params, x)
  vcall(:broadcast, :log, x)
end

ops[:Neg] = function(params, x)
  vcall(:*, -1,  x)
end

ops[:Sum] = function (params, x, y)
  vcall(:+, x,y)
end

ops[:Constant] = function (params)
  constant(Symbol("weights[\"$(params.name)\"]"))
end

ops[:Ceil] = function (params ,x)
  vcall(:broadcast, :ceil, x)
end

ops[:Reshape] = function(params, tensor1, shape)
  vcall(:reshape, tensor1, vcall(:Tuple, vcall(:reverse, shape)))
end

ops[:Reshape] = function(params, tensor1)
  vcall(:reshape, tensor1, (params[:shape]...))
end

ops[:LRN] = function(params, x)
  vcall(:identity, x)             # Needed: Flux support for LRN
end

#To-Do : add broadcast here (Urgent)
#         Add axis condition here
ops[:Add] = function(params, A, B)
  if haskey(params, :broadcast) && params[:broadcast] == 1
    if !haskey(params , :axis)
      return vcall(:.+, A, B)
    end
    return vcall( :Add,params[:axis], A, B)                  # To-DO : Define Add function  
  else
    # Broadcast not defined: Perform normal addition.
    return vcall(:+, A, B)
  end
end

ops[:Sub] = function(params, A , B)
  if haskey(params, :broadcast) && params[:broadcast] == 1
    if !haskey(params , :axis)
      return vcall(:.-, A, B)
    end
    return vcall( :Sub,params[:axis], A, B)                  # To-DO : Define Sub function  
  else
    # Broadcast not defined: Perform normal sub.
    return vcall(:-, A, B)
  end
end

ops[:Div] = function(params, A , B)
  if (haskey(params, :broadcast) && params[:broadcast] == 1)
    if !haskey(params, :axis)
      return vcall(:./, A, B)
    end
    return vcall( :Div, params[:axis], A, B)              # To-Do define Div function
  else
    return vcall(:./  , A, B)   # In case of no broadcast, Perform normal div operation.
  end
end

ops[:Mul] = function (params, A, B)
  if (haskey(params, :broadcast) && params[:broadcast] == 1)
    if !haskey(params, :axis)
      return vcall(:.*, A, B)
    end
    return vcall( :Mul, params[:axis], A, B)              # To-Do define Mul function
  else
    return vcall(:.*, A, B)   # In case of no broadcast, Perform normal Mul operation.
  end
end

ops[:Pow] = function (params, A, B)
  if (haskey(params, :broadcast) && params[:broadcast] == 1)
    if !haskey(params, :axis)
      return vcall(:.^, A, B)
    end
    return vcall( :Pow, params[:axis], A, B)              # To-Do define Pow function
  else
    return vcall(:.^, A, B)   # In case of no broadcast, Perform normal Power operation.
  end
end

ops[:MatMul] = function(params, A, B)
  tempa = vcall(:permutedims, A, vcall(:reverse, vcall(:range, 1, vcall(:ndims, A))))
  tempb = vcall(:permutedims, B, vcall(:reverse, vcall(:range, 1, vcall(:ndims, B))))
  vcall(:permutedims, vcall(:*, tempa, tempb), vcall(:reverse, vcall(:range, 1, vcall(:ndims, vcall(:*, tempa, tempb)))))
end

ops[:size] = function(params, A)
  vcall(:prod, vcall(:size, A))
end

ops[:Sqrt] = function(params, A)
  vcall(:broadcast, :sqrt, A)
end

ops[:Reciprocal] = function(params, A)
  vcall(:./ , 1, A)
end

ops[:And] = function(params, A, B)
  if (haskey(params, :broadcast) && params[:broadcast] == 1)
    if !haskey(params, :axis)
      return vcall(:.*, vcall(:broadcast, :Bool, A), vcall(:broadcast, :Bool, B))
    end
    return vcall( :And, params[:axis], A, B)              # To-Do define And function
  else
    return vcall(:.*, vcall(:broadcast, :Bool, A), vcall(:broadcast, :Bool, B))   # In case of no broadcast, 
                                                                                    #Perform normal And operation.
  end
end

ops[:Or] = function(params, A, B)
  if (haskey(params, :broadcast) && params[:broadcast] == 1)
    if !haskey(params, :axis)
      return vcall(:.+, vcall(:broadcast, :Bool, A), vcall(:broadcast, :Bool, B))
    end
    return vcall( :Or, params[:axis], A, B)              # To-Do define Or function
  else
    return vcall(:.+, vcall(:broadcast, :Bool, A), vcall(:broadcast, :Bool, B))   # In case of no broadcast, 
                                                                                    #Perform normal Or operation.
  end
end
# Preprocessing

ops[:ImageScaler] = function(params, A)
  if !haskey(params, :scale)
    params[:scale] = 1
  end
  vcall(:.*, A, params[:scale])
end