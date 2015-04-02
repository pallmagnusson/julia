### Multidimensional iterators
module IteratorsMD

import Base: eltype, length, start, done, next, last, getindex, setindex!, linearindexing, min, max, eachindex
import Base: simd_outer_range, simd_inner_length, simd_index
import Base: @nref, @ncall, @nif, @nexprs, LinearFast, LinearSlow, to_index

export CartesianIndex, CartesianRange

# Traits for linear indexing
linearindexing{A<:BitArray}(::Type{A}) = LinearFast()

# CartesianIndex
abstract CartesianIndex{N}

stagedfunction Base.call{N}(::Type{CartesianIndex},index::NTuple{N,Integer})
    indextype = gen_cartesian(N)
    return Expr(:call,indextype,[:(to_index(index[$i])) for i=1:N]...)
end
stagedfunction Base.call{N}(::Type{CartesianIndex{N}},index::Integer...)
    length(index) == N && return :(CartesianIndex(index))
    length(index) > N && throw(DimensionMismatch("Cannot create CartesianIndex{$N} from $(length(index)) indexes"))
    args = [i <= length(index) ? :(index[$i]) : 1 for i = 1:N]
    :(CartesianIndex(tuple($(args...))))
end
Base.call{M,N}(::Type{CartesianIndex{N}},index::NTuple{M,Integer}) = CartesianIndex{N}(index...)

let implemented = IntSet()
    global gen_cartesian
    function gen_cartesian(N::Int)
        # Create the types
        indextype = symbol("CartesianIndex_$N")
        if !in(N,implemented)
            fnames = [symbol("I_$i") for i = 1:N]
            fields = [Expr(:(::), fnames[i], :Int) for i = 1:N]
            extype = Expr(:type, false, Expr(:(<:), indextype, Expr(:curly, :CartesianIndex, N)), Expr(:block, fields...))
            eval(extype)
            argsleft = [Expr(:(::), fnames[i], :Integer) for i = 1:N]
            argsright = [Expr(:call,:to_index,fnames[i]) for i=1:N]
            exconstructor = Expr(:(=),Expr(:call,:(Base.call),:(::Type{CartesianIndex{$N}}),argsleft...),Expr(:call,indextype,argsright...))
            eval(exconstructor)
            push!(implemented,N)
        end
        return indextype
    end
end

# length
length{N}(::CartesianIndex{N})=N
length{N}(::Type{CartesianIndex{N}})=N
length{I<:CartesianIndex}(::Type{I})=length(super(I))

# indexing
getindex(index::CartesianIndex, i::Integer) = getfield(index, i)::Int

stagedfunction setindex!{T,N}(A::Array{T}, v, index::CartesianIndex{N})
    :(Base.arrayset(A, convert($T,v), $(cartindex_exprs((index,), (:index,))...)))
end
stagedfunction setindex!{T,N}(A::Array{T}, v, i::Integer, index::CartesianIndex{N})
    :(Base.arrayset(A, convert($T,v), $(cartindex_exprs((i, index), (:i, :index))...)))
end
stagedfunction setindex!{T,M,N}(A::Array{T}, v, index1::CartesianIndex{M}, i::Integer, index2::CartesianIndex{N})
    :(Base.arrayset(A, convert($T,v), $(cartindex_exprs((index1, i, index2), (:index1, :i, :index2))...)))
end

stagedfunction getindex{N}(A::AbstractArray, index::CartesianIndex{N})
    :(getindex(A, $(cartindex_exprs((index,), (:index,))...)))
end
stagedfunction getindex{N}(A::AbstractArray, i::Integer, index::CartesianIndex{N})
    :(getindex(A, $(cartindex_exprs((i, index), (:i, :index))...)))
end
stagedfunction setindex!{T,N}(A::AbstractArray{T}, v, index::CartesianIndex{N})
    :(setindex!(A, v, $(cartindex_exprs((index,), (:index,))...)))
end
stagedfunction setindex!{T,N}(A::AbstractArray{T}, v, i::Integer, index::CartesianIndex{N})
    :(setindex!(A, v, $(cartindex_exprs((i, index), (:i, :index))...)))
end
for AT in (AbstractVector, AbstractMatrix, AbstractArray)  # nix ambiguity warning
    @eval begin
        stagedfunction getindex{M,N}(A::$AT, index1::CartesianIndex{M}, i::Integer, index2::CartesianIndex{N})
            :(getindex(A, $(cartindex_exprs((index1, i, index2), (:index1, :i, :index2))...)))
        end
        stagedfunction setindex!{M,N}(A::$AT, v, index1::CartesianIndex{M}, i::Integer, index2::CartesianIndex{N})
            :(setindex!(A, v, $(cartindex_exprs((index1, i, index2), (:index1, :i, :index2))...)))
        end
    end
end

function cartindex_exprs(indexes, syms)
    exprs = Any[]
    for (i,ind) in enumerate(indexes)
        if ind <: Number
            push!(exprs, :($(syms[i])))
        else
            for j = 1:length(ind)
                push!(exprs, :($(syms[i])[$j]))
            end
        end
    end
    if isempty(exprs)
        push!(exprs, 1)  # Handle the zero-dimensional case
    end
    exprs
end

# arithmetic, min/max
for op in (:+, :-, :min, :max)
    @eval begin
        stagedfunction ($op){N}(index1::CartesianIndex{N}, index2::CartesianIndex{N})
            I = index1
            args = [:($($op)(index1[$d],index2[$d])) for d = 1:N]
            :($I($(args...)))
        end
    end
end

stagedfunction *{N}(a::Integer, index::CartesianIndex{N})
    I = index
    args = [:(a*index[$d]) for d = 1:N]
    :($I($(args...)))
end
*(index::CartesianIndex,a::Integer)=*(a,index)

# Iteration
immutable CartesianRange{I<:CartesianIndex}
    start::I
    stop::I
end

stagedfunction CartesianRange{N}(I::CartesianIndex{N})
    startargs = fill(1, N)
    :(CartesianRange($I($(startargs...)), I))
end
CartesianRange{N}(sz::NTuple{N,Int}) = CartesianRange(CartesianIndex(sz))

stagedfunction eachindex{T,N}(::LinearSlow, A::AbstractArray{T,N})
    startargs = fill(1, N)
    stopargs = [:(size(A,$i)) for i=1:N]
    meta = Expr(:meta, :inline)
    :($meta; CartesianRange(CartesianIndex{$N}($(startargs...)), CartesianIndex{$N}($(stopargs...))))
end

eltype{I}(::Type{CartesianRange{I}}) = I
eltype{I}(::CartesianRange{I}) = I

start(iter::CartesianRange) = iter.start
stagedfunction next{I<:CartesianIndex}(iter::CartesianRange{I}, state)
    N = length(I)
    meta = Expr(:meta, :inline)
    quote
        $meta
        index=state
        @nif $N d->(index[d] < iter.stop[d]) d->(@nexprs($N, k->(ind_k = ifelse(k>=d, index[k] + (k==d), iter.start[k]))))
        newindex = @ncall $N $I ind
        index, newindex
    end
end
stagedfunction done{I<:CartesianIndex}(iter::CartesianRange{I}, state)
    N = length(I)
    :(state[$N] > iter.stop[$N])
end

# 0-d cartesian ranges are special-cased to iterate once and only once
start{I<:CartesianIndex{0}}(iter::CartesianRange{I}) = false
next{I<:CartesianIndex{0}}(iter::CartesianRange{I}, state) = iter.start, true
done{I<:CartesianIndex{0}}(iter::CartesianRange{I}, state) = state

stagedfunction length{I<:CartesianIndex}(iter::CartesianRange{I})
    N = length(I)
    N == 0 && return 1
    args = [:(iter.stop[$i]-iter.start[$i]+1) for i=1:N]
    Expr(:call,:*,args...)
end

last(iter::CartesianRange) = iter.stop

stagedfunction simd_outer_range{I}(iter::CartesianRange{I})
    N = length(I)
    N == 0 && return :(CartesianRange(CartesianIndex{0}(),CartesianIndex{0}()))
    startargs = [:(iter.start[$i]) for i=2:N]
    stopargs  = [:(iter.stop[$i]) for i=2:N]
    :(CartesianRange(CartesianIndex{$(N-1)}($(startargs...)), CartesianIndex{$(N-1)}($(stopargs...))))
end

simd_inner_length{I<:CartesianIndex{0}}(iter::CartesianRange{I}, ::CartesianIndex) = 1
simd_inner_length(iter::CartesianRange, I::CartesianIndex) = iter.stop[1]-iter.start[1]+1

simd_index{I<:CartesianIndex{0}}(iter::CartesianRange{I}, ::CartesianIndex, I1::Int) = iter.start
stagedfunction simd_index{N}(iter::CartesianRange, Ilast::CartesianIndex{N}, I1::Int)
    args = [d == 1 ? :(I1+iter.start[1]) : :(Ilast[$(d-1)]) for d = 1:N+1]
    meta = Expr(:meta, :inline)
    :($meta; CartesianIndex{$(N+1)}($(args...)))
end

end  # IteratorsMD

using .IteratorsMD

### From abstractarray.jl: Internal multidimensional indexing definitions ###
# These are not defined on directly ongetindex and unsafe_getindex to avoid
# ambiguities for AbstractArray subtypes. See the note in abstractarray.jl

# Note that it's most efficient to call checkbounds first, and then to_index
@inline function _getindex(l::LinearIndexing, A::AbstractArray, I::Union(Real, AbstractArray, Colon)...)
    checkbounds(A, I...)
    _unsafe_getindex(l, A, I...)
end
stagedfunction _unsafe_getindex(l::LinearIndexing, A::AbstractArray, I::Union(Real, AbstractArray, Colon)...)
    N = length(I)
    quote
        $(Expr(:meta, :inline))
        @nexprs $N d->(I_d = to_index(I[d]))
        dest = similar(A, @ncall $N index_shape A I)
        @ncall $N checksize dest I
        @ncall $N _unsafe_getindex! dest l A I
    end
end

# logical indexing optimization - don't use find (within to_index)
# This is inherently a linear operation in the source, but we could potentially
# use fast dividing integers to speed it up.
function _unsafe_getindex(::LinearIndexing, src::AbstractArray, I::AbstractArray{Bool})
    # Both index_shape and checksize compute sum(I); manually hoist it out
    N = sum(I)
    dest = similar(src, (N,))
    size(dest) == (N,) || throw(DimensionMismatch())
    D = eachindex(dest)
    Ds = start(D)
    s = 0
    for b in I
        s+=1
        if b
            d, Ds = next(D, Ds)
            unsafe_setindex!(dest, src[s], d)
        end
    end
    dest
end

# Indexing with an array of indices is inherently linear in the source, but
# might be able to be optimized with fast dividing integers
function _unsafe_getindex!(dest::AbstractArray, ::LinearIndexing, src::AbstractArray, I::AbstractArray)
    D = eachindex(dest)
    Ds = start(D)
    for idx in I
        d, Ds = next(D, Ds)
        unsafe_setindex!(dest, unsafe_getindex(src, idx), d)
    end
    dest
end

# Fast source - compute the linear index
stagedfunction _unsafe_getindex!(dest::AbstractArray, ::LinearFast, src::AbstractArray, I::Union(Real, AbstractVector, Colon)...)
    N = length(I)
    quote
        stride_1 = 1
        @nexprs $N d->(stride_{d+1} = stride_d*size(src, d))
        $(symbol(:offset_, N)) = 1
        D = eachindex(dest)
        Ds = start(D)
        @nloops $N i dest d->(offset_{d-1} = offset_d + (unsafe_getindex(I[d], i_d)-1)*stride_d) begin
            d, Ds = next(D, Ds)
            unsafe_setindex!(dest, unsafe_getindex(src, offset_0), d)
        end
        dest
    end
end
# Slow source - index with the indices provided.
# TODO: this may not be the full dimensionality; that case could be optimized
stagedfunction _unsafe_getindex!(dest::AbstractArray, ::LinearSlow, src::AbstractArray, I::Union(Real, AbstractVector, Colon)...)
    N = length(I)
    quote
        D = eachindex(dest)
        Ds = start(D)
        @nloops $N i dest d->(j_d = unsafe_getindex(I[d], i_d)) begin
            d, Ds = next(D, Ds)
            v = @ncall $N unsafe_getindex src j
            unsafe_setindex!(dest, v, d)
        end
        dest
    end
end

# checksize ensures the output array A is the correct size for the given indices
checksize(A::AbstractArray, I::AbstractArray) = size(A) == size(I) || throw(DimensionMismatch("index 1 has size $(size(I)), but size(A) = $(size(A))"))
checksize(A::AbstractArray, I::AbstractArray{Bool}) = length(A) == sum(I) || throw(DimensionMismatch("index 1 selects $(sum(I)) elements, but length(A) = $(length(A))"))
stagedfunction checksize(A::AbstractArray, I...)
    N = length(I)
    quote
        @nexprs $N d->(_checksize(A, d, I[d]) || throw(DimensionMismatch("index $d selects $(length(I[d])) elements, but size(A, $d) = $(size(A,d))")))
    end
end
_checksize(A::AbstractArray, dim, I) = size(A, dim) == length(I)
_checksize(A::AbstractArray, dim, I::AbstractVector{Bool}) = size(A, dim) == sum(I)
_checksize(A::AbstractArray, dim, ::Colon) = true
_checksize(A::AbstractArray, dim, ::Real) = size(A, dim) == 1

@inline unsafe_setindex!{T}(v::Array{T}, x::T, ind::Int) = (@inbounds v[ind] = x; v)
@inline unsafe_setindex!(v::BitArray, x::Bool, ind::Int) = (Base.unsafe_bitsetindex!(v.chunks, x, ind); v)
@inline unsafe_setindex!(v::BitArray, x, ind::Real) = (Base.unsafe_bitsetindex!(v.chunks, convert(Bool, x), to_index(ind)); v)

## setindex! ##
# For multi-element setindex!, we check bounds, convert the indices (to_index),
# and ensure the value to set is either an AbstractArray or a Repeated scalar
# before redispatching to the _unsafe_batchsetindex!
_iterable(v::AbstractArray) = v
_iterable(v) = repeated(v)
@inline function _setindex!(l::LinearIndexing, A::AbstractArray, x, J::Union(Real,AbstractArray,Colon)...)
    checkbounds(A, J...)
    _unsafe_setindex!(l, A, x, J...)
end
@inline function _unsafe_setindex!(l::LinearIndexing, A::AbstractArray, x, J::Union(Real,AbstractArray,Colon)...)
    _unsafe_batchsetindex!(l, A, _iterable(x), to_index(J)...)
end

# 1-d logical indexing: override the above to avoid calling find (in to_index)
function _unsafe_setindex!(::LinearIndexing, A::AbstractArray, x, I::AbstractArray{Bool})
    X = _iterable(x)
    setindex_shape_check(X, index_lengths(A, I)[1])
    Xs = start(X)
    i = 0
    for b in I
        i+=1
        if b
            (v, Xs) = next(X, Xs)
            unsafe_setindex!(A, v, i)
        end
    end
    A
end

# Use iteration over X so we don't need to worry about its storage
stagedfunction _unsafe_batchsetindex!(::LinearFast, A::AbstractArray, X, I::Union(Real,AbstractArray,Colon)...)
    N = length(I)
    quote
        @nexprs $N d->(I_d = I[d])
        idxlens = @ncall $N index_lengths A I
        @ncall $N setindex_shape_check X (d->idxlens[d])
        Xs = start(X)
        stride_1 = 1
        @nexprs $N d->(stride_{d+1} = stride_d*size(A,d))
        $(symbol(:offset_, N)) = 1
        @nloops $N i d->(1:idxlens[d]) d->(offset_{d-1} = offset_d + (unsafe_getindex(I_d, i_d)-1)*stride_d) begin
            v, Xs = next(X, Xs)
            unsafe_setindex!(A, v, offset_0)
        end
        A
    end
end
stagedfunction _unsafe_batchsetindex!(::LinearSlow, A::AbstractArray, X, I::Union(Real,AbstractArray,Colon)...)
    N = length(I)
    quote
        @nexprs $N d->(I_d = I[d])
        idxlens = @ncall $N index_lengths A I
        @ncall $N setindex_shape_check X (d->idxlens[d])
        Xs = start(X)
        @nloops $N i d->(1:idxlens[d]) d->(j_d = unsafe_getindex(I_d, i_d)) begin
            v, Xs = next(X, Xs)
            @ncall $N unsafe_setindex! A v j
        end
        A
    end
end

##

stagedfunction findn{T,N}(A::AbstractArray{T,N})
    quote
        nnzA = countnz(A)
        @nexprs $N d->(I_d = Array(Int, nnzA))
        k = 1
        @nloops $N i A begin
            @inbounds if (@nref $N A i) != zero(T)
                @nexprs $N d->(I_d[k] = i_d)
                k += 1
            end
        end
        @ntuple $N I
    end
end

### subarray.jl

# This is the code-generation block for SubArray's staged setindex! function:
# _setindex!(V::SubArray, x, J::Union(Real,AbstractVector,Colon)...)
function gen_setindex_body(N::Int)
    quote
        Base.Cartesian.@nexprs $N d->(J_d = J[d])
        Base.Cartesian.@ncall $N checkbounds V J
        Base.Cartesian.@nexprs $N d->(I_d = Base.to_index(J_d))
        idxlens = @ncall $N index_lengths V I
        if !isa(x, AbstractArray)
            Base.Cartesian.@nloops $N i d->(1:idxlens[d]) d->(@inbounds j_d = Base.unsafe_getindex(I_d, i_d)) begin
                @inbounds (Base.Cartesian.@nref $N V j) = x
            end
        else
            X = x
            setindex_shape_check(X, idxlens...)
            k = 1
            Base.Cartesian.@nloops $N i d->(1:idxlens[d]) d->(@inbounds j_d = Base.unsafe_getindex(I_d, i_d)) begin
                @inbounds (Base.Cartesian.@nref $N V j) = X[k]
                k += 1
            end
        end
        V
    end
end

## SubArray index merging
# A view created like V = A[2:3:8, 5:2:17] can later be indexed as V[2:7],
# creating a new 1d view.
# In such cases we have to collapse the 2d space spanned by the ranges.
#
# API:
#    merge_indexes(V, indexes::NTuple, dims::Dims, linindex)
# where dims encodes the trailing sizes of the parent array,
# indexes encodes the view's trailing indexes into the parent array,
# and linindex encodes the subset of these elements that we'll select.
#
# The generic algorithm makes use of div to convert elements
# of linindex into a cartesian index into indexes, looks up
# the corresponding cartesian index into the parent, and then uses
# dims to convert back to a linear index into the parent array.
#
# However, a common case is linindex::Range.
# Since div is slow and in(j::Int, linindex::Range) is fast,
# it can be much faster to generate all possibilities and
# then test whether the corresponding linear index is in linindex.
# One exception occurs when only a small subset of the total
# is desired, in which case we fall back to the div-based algorithm.
#stagedfunction merge_indexes{T<:Integer}(V, parentindexes::NTuple, parentdims::Dims, linindex::Union(Colon,Range{T}), lindim)
stagedfunction merge_indexes_in{TT}(V, parentindexes::TT, parentdims::Dims, linindex, lindim)
    N = length(parentindexes.parameters)   # number of parent axes we're merging
    N > 0 || throw(ArgumentError("cannot merge empty indexes"))
    lengthexpr = linindex == Colon ? (:(prod(size(V)[lindim:end]))) : (:(length(linindex)))
    L = symbol(string("Istride_", N+1))  # length of V's trailing dimensions
    quote
        n = $lengthexpr
        Base.Cartesian.@nexprs $N d->(I_d = parentindexes[d])
        pdimoffset = ndims(V.parent) - length(parentdims)
        Istride_1 = 1   # parentindexes strides
        Base.Cartesian.@nexprs $N d->(Istride_{d+1} = Istride_d*dimsize(V.parent, d+pdimoffset, I_d))
        Istridet = Base.Cartesian.@ntuple $(N+1) d->Istride_d
        if n < 0.1*$L   # this has not been carefully tuned
            return merge_indexes_div(V, parentindexes, parentdims, linindex, lindim)
        end
        Pstride_1 = 1   # parent strides
        Base.Cartesian.@nexprs $(N-1) d->(Pstride_{d+1} = Pstride_d*parentdims[d])
        Base.Cartesian.@nexprs $N d->(counter_d = 1) # counter_0 is a linear index into parentindexes
        Base.Cartesian.@nexprs $N d->(offset_d = 1)  # offset_0 is a linear index into parent
        k = 0
        index = Array(Int, n)
        Base.Cartesian.@nloops $N i d->(1:dimsize(V.parent, d+pdimoffset, I_d)) d->(offset_{d-1} = offset_d + (I_d[i_d]-1)*Pstride_d; counter_{d-1} = counter_d + (i_d-1)*Istride_d) begin
            if in(counter_0, linindex)
                index[k+=1] = offset_0
            end
        end
        index
    end
end

# HACK: dispatch seemingly wasn't working properly
function merge_indexes(V, parentindexes::NTuple, parentdims::Dims, linindex, lindim)
    if isa(linindex, Colon) || isa(linindex, Range)
        return merge_indexes_in(V, parentindexes, parentdims, linindex, lindim)
    end
    merge_indexes_div(V, parentindexes, parentdims, linindex, lindim)
end

# Even simpler is the case where the linear index is ::Colon: return all indexes
stagedfunction merge_indexes(V, indexes::NTuple, dims::Dims, ::Colon)
    N = length(indexes)
    N > 0 || throw(ArgumentError("cannot merge empty indexes"))
    quote
        Base.Cartesian.@nexprs $N d->(I_d = indexes[d])
        dimoffset = ndims(V.parent) - length(dims)
        n = prod(map(length, indexes))
        Pstride_1 = 1   # parent strides
        Base.Cartesian.@nexprs $(N-1) d->(Pstride_{d+1} = Pstride_d*dims[d])
        Base.Cartesian.@nexprs $N d->(offset_d = 1)  # offset_0 is a linear index into parent
        k = 0
        index = Array(Int, n)
        Base.Cartesian.@nloops $N i d->(1:dimsize(V, d+dimoffset, I_d)) d->(offset_{d-1} = offset_d + (I_d[i_d]-1)*Pstride_d) begin
            index[k+=1] = offset_0
        end
        index
    end
end

# This could be written as a regular function, but performance
# will be better using Cartesian macros to avoid the heap and
# an extra loop.
stagedfunction merge_indexes_div{TT}(V, parentindexes::TT, parentdims::Dims, linindex, lindim)
    N = length(parentindexes.parameters)
    N > 0 || throw(ArgumentError("cannot merge empty indexes"))
    Istride_N = symbol("Istride_$N")
    lengthexpr = :(length(linindex))
    quote
        Base.Cartesian.@nexprs $N d->(I_d = parentindexes[d])
        Pstride_1 = 1   # parent strides
        Base.Cartesian.@nexprs $(N-1) d->(Pstride_{d+1} = Pstride_d*parentdims[d])
        Istride_1 = 1   # parentindexes strides
        pdimoffset = ndims(V.parent) - length(parentdims)
        Base.Cartesian.@nexprs $(N-1) d->(Istride_{d+1} = Istride_d*dimsize(V.parent, d+pdimoffset, I_d))
        n = $lengthexpr
        L = $(Istride_N) * dimsize(V.parent, $N+pdimoffset, parentindexes[end])
        index = Array(Int, n)
        for i = 1:n
            k = linindex[i] # k is the parentindexes-centered linear index
            1 <= k <= L || throw(BoundsError())
            k -= 1
            j = 0  # j will be the new parent-centered linear index
            Base.Cartesian.@nexprs $N d->(d < $N ?
                begin
                    c, k = divrem(k, Istride_{$N-d+1})
                    j += (Base.unsafe_getindex(I_{$N-d+1}, c+1)-1)*Pstride_{$N-d+1}
                end : begin
                    j += Base.unsafe_getindex(I_1, k+1)
                end)
            index[i] = j
        end
        index
    end
end


 cumsum(A::AbstractArray, axis::Integer=1) =  cumsum!(similar(A, Base._cumsum_type(A)), A, axis)
cumsum!(B, A::AbstractArray) = cumsum!(B, A, 1)
cumprod(A::AbstractArray, axis::Integer=1) = cumprod!(similar(A), A, axis)
cumprod!(B, A) = cumprod!(B, A, 1)

for (f, op) in ((:cumsum!, :+),
                (:cumprod!, :*))
    @eval begin
        stagedfunction ($f){T,N}(B, A::AbstractArray{T,N}, axis::Integer)
            quote
                if size(B, axis) < 1
                    return B
                end
                size(B) == size(A) || throw(DimensionMismatch("Size of B must match A"))
                if axis == 1
                    # We can accumulate to a temporary variable, which allows register usage and will be slightly faster
                    @inbounds @nloops $N i d->(d > 1 ? (1:size(A,d)) : (1:1)) begin
                        tmp = convert(eltype(B), @nref($N, A, i))
                        @nref($N, B, i) = tmp
                        for i_1 = 2:size(A,1)
                            tmp = ($($op))(tmp, @nref($N, A, i))
                            @nref($N, B, i) = tmp
                        end
                    end
                else
                    @nexprs $N d->(isaxis_d = axis == d)
                    # Copy the initial element in each 1d vector along dimension `axis`
                    @inbounds @nloops $N i d->(d == axis ? (1:1) : (1:size(A,d))) @nref($N, B, i) = @nref($N, A, i)
                    # Accumulate
                    @inbounds @nloops $N i d->((1+isaxis_d):size(A, d)) d->(j_d = i_d - isaxis_d) begin
                        @nref($N, B, i) = ($($op))(@nref($N, B, j), @nref($N, A, i))
                    end
                end
                B
            end
        end
    end
end

### from abstractarray.jl

function fill!{T}(A::AbstractArray{T}, x)
    xT = convert(T, x)
    for I in eachindex(A)
        @inbounds A[I] = xT
    end
    A
end

function copy!{T,N}(dest::AbstractArray{T,N}, src::AbstractArray{T,N})
    samesize = true
    for d = 1:N
        if size(dest,d) != size(src,d)
            samesize = false
            break
        end
    end
    if samesize && linearindexing(dest) == linearindexing(src)
        for I in eachindex(dest)
            @inbounds dest[I] = src[I]
        end
    else
        length(dest) >= length(src) || throw(BoundsError())
        iterdest = eachindex(dest)
        sdest = start(iterdest)
        for Isrc in eachindex(src)
            Idest, sdest = next(iterdest, sdest)
            @inbounds dest[Idest] = src[Isrc]
        end
    end
    dest
end

### BitArrays

## getindex

@inline unsafe_getindex(v::BitArray, ind::Int) = Base.unsafe_bitgetindex(v.chunks, ind)
@inline unsafe_setindex!(v::BitArray, x::Bool, ind::Int) = (Base.unsafe_bitsetindex!(v.chunks, x, ind); v)

# contiguous multidimensional indexing: if the first dimension is a range,
# we can get some performance from using copy_chunks!

function unsafe_getindex(B::BitArray, I0::UnitRange{Int})
    X = BitArray(length(I0))
    copy_chunks!(X.chunks, 1, B.chunks, first(I0), length(I0))
    return X
end

function getindex(B::BitArray, ::Colon)
    X = BitArray(0)
    X.chunks = copy(B.chunks)
    X.len = length(B)
    return X
end

# Optimization where the inner dimension is contiguous
stagedfunction unsafe_getindex(B::BitArray, I0::Union(Colon,UnitRange{Int}), I::Union(Int,UnitRange{Int},Colon)...)
    N = length(I)
    Isplat = Expr[:(I[$d]) for d = 1:N]
    quote
        @nexprs $N d->(I_d = I[d])
        X = BitArray(index_shape(B, I0, $(Isplat...)))

        f0 = first(I0)
        l0 = size(X, 1)

        gap_lst_1 = 0
        @nexprs $N d->(gap_lst_{d+1} = size(X, d+1))
        stride = 1
        ind = f0
        @nexprs $N d->begin
            stride *= size(B, d)
            stride_lst_d = stride
            ind += stride * (first(I_d) - 1)
            gap_lst_{d+1} *= stride
        end

        storeind = 1
        @nloops($N, i, d->I_d,
                d->nothing, # PRE
                d->(ind += stride_lst_d - gap_lst_d), # POST
                begin # BODY
                    copy_chunks!(X.chunks, storeind, B.chunks, ind, l0)
                    storeind += l0
                end)
        return X
    end
end

# # TODO? in the general multidimensional non-scalar case, can we do slightly
# # better by manually hoisting the offset calculations? If this is re-enabled,
# # dispatch must be altered to prevent scalar indexing from returning an array
# stagedfunction unsafe_getindex(B::BitArray, I::Union(Int,AbstractVector{Int},Colon)...)
#     N = length(I)
#     Isplat = Expr[:(I[$d]) for d = 1:N]
#     quote
#         @nexprs $N d->(I_d = I[d])
#         shape = @ncall $N index_shape B I
#         X = BitArray(shape)
#         Xc = X.chunks
#
#         stride_1 = 1
#         @nexprs $N d->(stride_{d+1} = stride_d * size(B, d))
#         @nexprs 1 d->(offset_{$N} = 1)
#         ind = 1
#         @nloops($N, i, X, d->(@inbounds j_d = unsafe_getindex(I[d], i_d);
#                               offset_{d-1} = offset_d + (j_d-1)*stride_d), # PRE
#                 begin
#                     unsafe_bitsetindex!(Xc, B[offset_0], ind)
#                     ind += 1
#                 end)
#         return X
#     end
# end


## setindex!

# general scalar indexing with two or more indices
# (uses linear indexing, which - in the safe version - performs the final
# bounds check and is defined in bitarray.jl)
# (code is duplicated for safe and unsafe versions for performance reasons)

stagedfunction unsafe_setindex!(B::BitArray, x::Bool, I_0::Int, I::Int...)
    N = length(I)
    quote
        stride = 1
        index = I_0
        @nexprs $N d->begin
            stride *= size(B,d)
            index += (I[d] - 1) * stride
        end
        unsafe_setindex!(B, x, index)
        return B
    end
end

stagedfunction setindex!(B::BitArray, x::Bool, I_0::Int, I::Int...)
    N = length(I)
    quote
        stride = 1
        index = I_0
        @nexprs $N d->(I_d = I[d])
        @nexprs $N d->begin
            l = size(B,d)
            stride *= l
            1 <= I_{d-1} <= l || throw(BoundsError())
            index += (I_d - 1) * stride
        end
        B[index] = x
        return B
    end
end

# contiguous multidimensional indexing: if the first dimension is a range,
# we can get some performance from using copy_chunks!

function unsafe_setindex!(B::BitArray, X::BitArray, I0::UnitRange{Int})
    l0 = length(I0)
    l0 == 0 && return B
    f0 = first(I0)
    copy_chunks!(B.chunks, f0, X.chunks, 1, l0)
    return B
end

function unsafe_setindex!(B::BitArray, x::Bool, I0::UnitRange{Int})
    l0 = length(I0)
    l0 == 0 && return B
    f0 = first(I0)
    fill_chunks!(B.chunks, x, f0, l0)
    return B
end

stagedfunction unsafe_setindex!(B::BitArray, X::BitArray, I0::UnitRange{Int}, I::Union(Int,UnitRange{Int})...)
    N = length(I)
    quote
        length(X) == 0 && return B
        f0 = first(I0)
        l0 = length(I0)

        gap_lst_1 = 0
        @nexprs $N d->(gap_lst_{d+1} = length(I[d]))
        stride = 1
        ind = f0
        @nexprs $N d->begin
            stride *= size(B, d)
            stride_lst_d = stride
            ind += stride * (first(I[d]) - 1)
            gap_lst_{d+1} *= stride
        end

        refind = 1
        @nloops($N, i, d->I[d],
                d->nothing, # PRE
                d->(ind += stride_lst_d - gap_lst_d), # POST
                begin # BODY
                    copy_chunks!(B.chunks, ind, X.chunks, refind, l0)
                    refind += l0
                end)

        return B
    end
end

stagedfunction unsafe_setindex!(B::BitArray, x::Bool, I0::UnitRange{Int}, I::Union(Int,UnitRange{Int})...)
    N = length(I)
    quote
        f0 = first(I0)
        l0 = length(I0)
        l0 == 0 && return B
        @nexprs $N d->(length(I[d]) == 0 && return B)

        gap_lst_1 = 0
        @nexprs $N d->(gap_lst_{d+1} = length(I[d]))
        stride = 1
        ind = f0
        @nexprs $N d->begin
            stride *= size(B, d)
            stride_lst_d = stride
            ind += stride * (first(I[d]) - 1)
            gap_lst_{d+1} *= stride
        end

        @nloops($N, i, d->I[d],
                d->nothing, # PRE
                d->(ind += stride_lst_d - gap_lst_d), # POST
                fill_chunks!(B.chunks, x, ind, l0) # BODY
                )

        return B
    end
end


# general multidimensional non-scalar indexing

stagedfunction unsafe_setindex!(B::BitArray, X::AbstractArray, I::Union(Int,AbstractArray{Int},Colon)...)
    N = length(I)
    quote
        refind = 1
        @nexprs $N d->(I_d = I[d])
        idxlens = @ncall $N index_lengths B I
        @nloops $N i d->(1:idxlens[d]) d->(J_d = I_d[i_d]) @inbounds begin
            @ncall $N unsafe_setindex! B convert(Bool,X[refind]) J
            refind += 1
        end
        return B
    end
end

stagedfunction unsafe_setindex!(B::BitArray, x::Bool, I::Union(Int,AbstractArray{Int},Colon)...)
    N = length(I)
    quote
        @nexprs $N d->(I_d = I[d])
        idxlens = @ncall $N index_lengths B I
        @nloops $N i d->(1:idxlens[d]) d->(J_d = I_d[i_d]) begin
            @ncall $N unsafe_setindex! B x J
        end
        return B
    end
end

# general versions with Real (or logical) indexing which dispatch on the appropriate method

# this one is for disambiguation only
function setindex!(B::BitArray, x, i::Real)
    checkbounds(B, i)
    return unsafe_setindex!(B, convert(Bool,x), to_index(i))
end

stagedfunction setindex!(B::BitArray, x, I::Union(Real,AbstractArray,Colon)...)
    N = length(I)
    quote
        checkbounds(B, I...)
        #return unsafe_setindex!(B, convert(Bool,x), to_index(I...)...) # segfaults! (???)
        @nexprs $N d->(J_d = to_index(I[d]))
        return @ncall $N unsafe_setindex! B convert(Bool,x) J
    end
end


# this one is for disambiguation only
function setindex!(B::BitArray, X::AbstractArray, i::Real)
    checkbounds(B, i)
    j = to_index(i)
    setindex_shape_check(X, index_lengths(A, j)[1])
    return unsafe_setindex!(B, X, j)
end

stagedfunction setindex!(B::BitArray, X::AbstractArray, I::Union(Real,AbstractArray,Colon)...)
    N = length(I)
    quote
        checkbounds(B, I...)
        @nexprs $N d->(J_d = to_index(I[d]))
        idxlens = @ncall $N index_lengths B J
        setindex_shape_check(X, idxlens...)
        return @ncall $N unsafe_setindex! B X J
    end
end



## findn

stagedfunction findn{N}(B::BitArray{N})
    quote
        nnzB = countnz(B)
        I = ntuple($N, x->Array(Int, nnzB))
        if nnzB > 0
            count = 1
            @nloops $N i B begin
                if (@nref $N B i) # TODO: should avoid bounds checking
                    @nexprs $N d->(I[d][count] = i_d)
                    count += 1
                end
            end
        end
        return I
    end
end

## isassigned

stagedfunction isassigned(B::BitArray, I_0::Int, I::Int...)
    N = length(I)
    quote
        @nexprs $N d->(I_d = I[d])
        stride = 1
        index = I_0
        @nexprs $N d->begin
            l = size(B,d)
            stride *= l
            1 <= I_{d-1} <= l || return false
            index += (I_d - 1) * stride
        end
        return isassigned(B, index)
    end
end

## permutedims

for (V, PT, BT) in [((:N,), BitArray, BitArray), ((:T,:N), Array, StridedArray)]
    @eval stagedfunction permutedims!{$(V...)}(P::$PT{$(V...)}, B::$BT{$(V...)}, perm)
        quote
            dimsB = size(B)
            length(perm) == N || throw(ArgumentError("expected permutation of size $N, but length(perm)=$(length(perm))"))
            isperm(perm) || throw(ArgumentError("input is not a permutation"))
            dimsP = size(P)
            for i = 1:length(perm)
                dimsP[i] == dimsB[perm[i]] || throw(DimensionMismatch("destination tensor of incorrect size"))
            end

            #calculates all the strides
            strides_1 = 0
            @nexprs $N d->(strides_{d+1} = stride(B, perm[d]))

            #Creates offset, because indexing starts at 1
            offset = 1 - sum(@ntuple $N d->strides_{d+1})

            if isa(B, SubArray)
                offset += first_index(B::SubArray) - 1
                B = B.parent
            end

            ind = 1
            @nexprs 1 d->(counts_{$N+1} = strides_{$N+1}) # a trick to set counts_($N+1)
            @nloops($N, i, P,
                    d->(counts_d = strides_d), # PRE
                    d->(counts_{d+1} += strides_{d+1}), # POST
                    begin # BODY
                        sumc = sum(@ntuple $N d->counts_{d+1})
                        @inbounds P[ind] = B[sumc+offset]
                        ind += 1
                    end)

            return P
        end
    end
end

## unique across dim

# TODO: this doesn't fit into the new hashing scheme in any obvious way

immutable Prehashed
    hash::UInt
end
hash(x::Prehashed) = x.hash

stagedfunction unique{T,N}(A::AbstractArray{T,N}, dim::Int)
    quote
        1 <= dim <= $N || return copy(A)
        hashes = zeros(UInt, size(A, dim))

        # Compute hash for each row
        k = 0
        @nloops $N i A d->(if d == dim; k = i_d; end) begin
            @inbounds hashes[k] = hash(hashes[k], hash((@nref $N A i)))
        end

        # Collect index of first row for each hash
        uniquerow = Array(Int, size(A, dim))
        firstrow = Dict{Prehashed,Int}()
        for k = 1:size(A, dim)
            uniquerow[k] = get!(firstrow, Prehashed(hashes[k]), k)
        end
        uniquerows = collect(values(firstrow))

        # Check for collisions
        collided = falses(size(A, dim))
        @inbounds begin
            @nloops $N i A d->(if d == dim
                k = i_d
                j_d = uniquerow[k]
            else
                j_d = i_d
            end) begin
                if (@nref $N A j) != (@nref $N A i)
                    collided[k] = true
                end
            end
        end

        if any(collided)
            nowcollided = BitArray(size(A, dim))
            while any(collided)
                # Collect index of first row for each collided hash
                empty!(firstrow)
                for j = 1:size(A, dim)
                    collided[j] || continue
                    uniquerow[j] = get!(firstrow, Prehashed(hashes[j]), j)
                end
                for v in values(firstrow)
                    push!(uniquerows, v)
                end

                # Check for collisions
                fill!(nowcollided, false)
                @nloops $N i A d->begin
                    if d == dim
                        k = i_d
                        j_d = uniquerow[k]
                        (!collided[k] || j_d == k) && continue
                    else
                        j_d = i_d
                    end
                end begin
                    if (@nref $N A j) != (@nref $N A i)
                        nowcollided[k] = true
                    end
                end
                (collided, nowcollided) = (nowcollided, collided)
            end
        end

        @nref $N A d->d == dim ? sort!(uniquerows) : (1:size(A, d))
    end
end
