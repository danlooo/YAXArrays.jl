module Datasets
#import ..Cubes.Axes: axsym, axname, CubeAxis, findAxis, CategoricalAxis, RangeAxis, caxes
import ..Cubes: Cubes, YAXArray, concatenatecubes, CleanMe, subsetcube, copy_diskarray, setchunks, caxes, readcubedata, cubesize, formatbytes
using ...YAXArrays: YAXArrays, YAXDefaults, findAxis
using DataStructures: OrderedDict, counter
using Dates: Day, Hour, Minute, Second, Month, Year, Date, DateTime, TimeType, AbstractDateTime, Period
using Statistics: mean
using IntervalSets: Interval, (..)
using CFTime: timedecode, timeencode, DateTimeNoLeap, DateTime360Day, DateTimeAllLeap
using YAXArrayBase
using YAXArrayBase: iscontdimval, add_var
using DiskArrayTools: CFDiskArray, diskstack
using DiskArrays: DiskArrays, GridChunks, ConcatDiskArray
using Glob: glob
using DimensionalData: DimensionalData as DD

export Dataset, Cube, open_dataset, to_dataset, savecube, savedataset, open_mfdataset

"""
Dataset object which stores an `OrderedDict` of YAXArrays with Symbol keys.
A dictionary of CubeAxes and a Dictionary of general properties.
A dictionary can hold cubes with differing axes. But it will share the common axes between the subcubes.
"""
struct Dataset
    cubes::OrderedDict{Symbol,YAXArray}
    axes::Dict{Symbol,DD.Dimension}
    properties::Dict
end
"""
    Dataset(; properties = Dict{String,Any}, cubes...)

Construct a YAXArray Dataset with global attributes `properties` a and a list of named YAXArrays cubes...
"""
function Dataset(; properties = Dict{String,Any}(), cubes...)
    axesall = Set{DD.Dimension}()
    foreach(values(cubes)) do c
        ax = DD.dims(c)
        foreach(a -> push!(axesall, a), ax)
    end
    axesall = collect(axesall)
    axnameall = DD.name.(axesall)
    axesnew = Dict{Symbol,DD.Dimension}(axnameall[i] => axesall[i] for i = eachindex(axesall))
    Dataset(OrderedDict(cubes), axesnew, properties)
end

"""
    to_dataset(c;datasetaxis = "Variables", layername = "layer")

Convert a Data Cube into a Dataset. It is possible to treat one of
the Cube's axes as a `datasetaxis` i.e. the cube will be split into
different parts that become variables in the Dataset. If no such
axis is specified or found, there will only be a single variable
in the dataset with the name `layername`.
"""
function to_dataset(c;datasetaxis = "Variables", layername = get(c.properties,"name","layer"))
    axlist = DD.dims(c)
    splice_generic(x::AbstractArray, i) = [x[1:(i-1)]; x[(i+1:end)]]
    splice_generic(x::Tuple, i) = (x[1:(i-1)]..., x[(i+1:end)]...)
    finalperm = nothing
    idatasetax = datasetaxis === nothing ? nothing : findAxis(datasetaxis, collect(axlist))
    chunks = DiskArrays.eachchunk(c).chunks
    if idatasetax !== nothing
        groupaxis = axlist[idatasetax]
        axlist = splice_generic(axlist, idatasetax)
        chunks = splice_generic(chunks, idatasetax)
        finalperm =
        ((1:idatasetax-1)..., length(axlist) + 1, (idatasetax:length(axlist))...)
    else
        groupaxis = nothing
    end
    if groupaxis === nothing
        cubenames = [layername]
    else
        cubenames = DD.lookup(groupaxis)
    end
    viewinds = ntuple(_->Colon(),ndims(c))
    atts = getattributes(c)
    allcubes = map(enumerate(cubenames)) do (i,cn)
        if idatasetax !== nothing
            viewinds = Base.setindex(viewinds,i,idatasetax)
            Symbol(cn)=>YAXArray(axlist, view(getdata(c),viewinds...), copy(atts),chunks=GridChunks(chunks),cleaner=c.cleaner)
        else
            Symbol(cn)=>YAXArray(axlist, getdata(c), copy(atts),chunks=GridChunks(chunks),cleaner=c.cleaner)
        end

    end

    axlist = Dict(Symbol(DD.name(ax))=>ax for ax in axlist)
    attrs = Dict{String,Any}()
    !isnothing(finalperm) && (attrs["_CubePerm"] = collect(finalperm))
    Dataset(OrderedDict(allcubes),axlist,attrs)
end

function Base.show(io::IO, ds::Dataset)
    # Find axes shared by all cubes
    sharedaxs = length(ds.cubes) > 0 ? intersect([caxes(c) for (n, c) in ds.cubes]...) : ()
    # Create a dictionary to store groups of variables by their axes
    axis_groups = Dict()
    variables_with_shared_axes_only = []  # List to hold variables that share all axes
    # Group variables by their axes, excluding shared axes
    for (var_name, cube) in ds.cubes
        axes = tuple(setdiff(caxes(cube), sharedaxs)...)
        if isempty(axes)
            push!(variables_with_shared_axes_only, var_name)  # Track variables that share all axes
        else
            if haskey(axis_groups, axes)
                push!(axis_groups[axes], var_name)
            else
                axis_groups[axes] = [var_name]
            end
        end
    end
    sorted_axis_groups = sort(collect(axis_groups), by = x -> length(x[2]))
    # Print header
    println(io, "YAXArray Dataset")
    # Print shared axes
    println(io, "Shared Axes: ")
    if !isempty(sharedaxs)
        DD.Dimensions.print_dims(io, MIME("text/plain"), tuple(sharedaxs...))
        println(io, "\n")
    else
        printstyled(io, "None", color=:light_black)
        print(io, "\n")
    end
    # Print variables that share all axes with sharedaxs (or variable without axis)
    if !isempty(variables_with_shared_axes_only)
        printstyled(io, "Variables: ", color=:light_blue)
        print(io, "\n")
        println(io, join(sort(variables_with_shared_axes_only), ", "))
        println(io)
    end

    # If there are additional axes, print variables grouped by those additional axes
    if !isempty(sorted_axis_groups)
        printstyled(io, "Variables with additional axes:", color=:light_yellow)
        for (axes, variables) in sorted_axis_groups
            print(io, "\n")
            if !isempty(axes)
                printstyled(io, "  Additional Axes: ", color=:light_black)
                print(io, "\n")
                DD.Dimensions.print_dims(io, MIME("text/plain"), axes)
                println(io)
            else
                print(io, "\n")
                printstyled(io, "  No additional axes:", color=:light_black)
                print(io, "\n")
            end
            printstyled(io, "  Variables: ", color=:light_blue)
            padding = " " ^ 2  # Adjust this number to match the length of "  Variables: "
            variables_str = join(sort(variables), ", ")
            padded_variables = padding * variables_str
            print(io, "\n")
            println(io, padded_variables)
        end
        print(io, "\n")
    end
    # Print properties if they exist
    if !isempty(ds.properties)
        printstyled(io, "Properties: ", color=:light_yellow)
        println(io, ds.properties)
    end
end

function Base.propertynames(x::Dataset, private::Bool = false)
    if private
        Symbol[:cubes; :axes; :properties; collect(keys(x.cubes)); collect(keys(x.axes))]
    else
        Symbol[collect(keys(x.cubes)); collect(keys(x.axes))]
    end
end
function Base.getproperty(x::Dataset, k::Symbol)
    if k === :cubes
        return getfield(x, :cubes)
    elseif k === :axes
        return getfield(x, :axes)
    elseif k === :properties
        return getfield(x, :properties)
    else
        x[k]
    end
end

function readcubedata(ds::Dataset)
    dssize = sum(cubesize.(values(ds.cubes)))
    if dssize > YAXDefaults.max_cache[]
        @warn "Loading data of size $(formatbytes(dssize))"
    end
    inmemcubes = OrderedDict(key=> readcubedata(val) for (key, val) in pairs(ds.cubes))
    Dataset(inmemcubes, ds.axes, ds.properties)
end

Base.getindex(x::Dataset, i::Symbol) =
haskey(x.cubes, i) ? x.cubes[i] :
haskey(x.axes, i) ? x.axes[i] : throw(ArgumentError("$i not found in Dataset"))
function Base.getindex(x::Dataset, i::Vector{Symbol})
    cubesnew = [j => x.cubes[j] for j in i]
    Dataset(; cubesnew...)
end
function DiskArrays.cache(ds::Dataset;maxsize=1000)
    #Distribute cache size equally across cubes
    maxsize = maxsize ÷ length(ds.cubes)
    cachedcubes = OrderedDict{Symbol,YAXArray}(
        k => DiskArrays.cache(ds.cubes[k];maxsize) for k in keys(ds.cubes)
    )
    Dataset(cachedcubes,ds.axes,ds.properties)
end


function fuzzyfind(s::String, comp::Vector{String})
    sl = lowercase(s)
    f = findall(i -> startswith(lowercase(i), sl), comp)
    if length(f) != 1
        throw(KeyError("Name $s not found"))
    else
        f[1]
    end
end
function Base.getindex(x::Dataset, i::Vector{String})
    istr = string.(keys(x.cubes))
    ids = map(name -> fuzzyfind(name, istr), i)
    syms = map(j -> Symbol(istr[j]), ids)
    cubesnew = [Symbol(i[j]) => x.cubes[syms[j]] for j = 1:length(ids)]
    Dataset(; cubesnew...)
end
Base.getindex(x::Dataset, i::String) = getproperty(x, Symbol(i))
function subsetifdimexists(a;kwargs...)
    axlist = DD.dims(a)
    kwargsshort = filter(kwargs) do kw
        findAxis(first(kw),axlist) !== nothing
    end

    # This makes no subsetting on cubes that do not have the respective axis.
    # Is this the behaviour we would expect?
    if !isempty(kwargsshort)
        getindex(a;kwargsshort...)
    else
        a
    end
end

function Base.getindex(x::Dataset; var = nothing, kwargs...)
    if var === nothing
        cc = x.cubes
        Dataset(; properties=x.properties, map(ds -> ds => subsetifdimexists(cc[ds]; kwargs...), collect(keys(cc)))...)
    elseif isa(var, String) || isa(var, Symbol)
        getindex(getproperty(x, Symbol(var)); kwargs...)
    else
        cc = x[var].cubes
        Dataset(; properties=x.properties, map(ds -> ds => subsetifdimexists(cc[ds]; kwargs...), collect(keys(cc)))...)
    end
end
function collectdims(g)
    dlist = Set{Tuple{String,Int,Int}}()
    varnames = get_varnames(g)
    foreach(varnames) do k
        d = get_var_dims(g, k)
        v = get_var_handle(g, k, persist=false)
        for (len, dname) in zip(size(v), d)
            if !occursin("bnd", dname) && !occursin("bounds", dname)
                datts = if dname in varnames
                    get_var_attrs(g, dname)
                else
                    Dict()
                end
                offs = get(datts, "_ARRAY_OFFSET", 0)
                push!(dlist, (dname, offs, len))
            end
        end
    end
    outd = Dict(d[1] => (ax = toaxis(d[1], g, d[2], d[3]), offs = d[2]) for d in dlist)
    length(outd) == length(dlist) ||
    throw(ArgumentError("All Arrays must have the same offset"))
    outd
end

function toaxis(dimname, g, offs, len)
    axname = Symbol(dimname)
    if !haskey(g, dimname)
        return DD.rebuild(DD.name2dim(axname), 1:len)
    end
    ar = get_var_handle(g, dimname, persist=false)
    aratts = get_var_attrs(g, dimname)
    if match(r"^(days)|(hours)|(seconds)|(months) since",lowercase(get(aratts,"units",""))) !== nothing
        tsteps = try
            timedecode(ar[:], aratts["units"], lowercase(get(aratts, "calendar", "standard")))
        catch
            ar[:]
        end
        DD.rebuild(DD.name2dim(axname), tsteps[offs+1:end])
    elseif haskey(aratts, "_ARRAYVALUES")
        vals = identity.(aratts["_ARRAYVALUES"])
        DD.rebuild(DD.name2dim(axname),(vals))
    else
        axdata = cleanaxiselement.(ar[offs+1:end])
        axdata = testrange(axdata)
        if eltype(axdata) <: AbstractString ||
            (!issorted(axdata) && !issorted(axdata, rev = true))
            DD.rebuild(DD.name2dim(axname), axdata)
        else
            DD.rebuild(DD.name2dim(axname), axdata)
        end
    end
end
propfromattr(attr) = Dict{String,Any}(filter(i -> i[1] != "_ARRAY_DIMENSIONS", attr))

#there are problems with saving custom string types to netcdf, so we clean this when creating the axis:
cleanaxiselement(x::AbstractString) = String(x)
cleanaxiselement(x::String) = x
cleanaxiselement(x::TimeType) = DateTime(x)
cleanaxiselement(x::Union{Date, DateTime}) = x
cleanaxiselement(x) = x

"Test if data in x can be approximated by a step range"
function testrange(x)
    isempty(x) && return x
    r = range(first(x), last(x), length = length(x))
    all(i -> isapprox(i...), zip(x, r)) ? r : x
end

function testrange(x::AbstractArray{<:Integer})
    steps = diff(x)
    if all(isequal(steps[1]), steps) && !iszero(steps[1])
        return range(first(x), step = steps[1], length = length(x))
    else
        return x
    end
end

using Dates: TimeType

testrange(x::AbstractArray{<:TimeType}) = x

testrange(x::AbstractArray{<:AbstractString}) = x


# This is a bit unfortunate since it will disallow globbing hierarchies of directories, 
# but necessary to have it work on both windows and Unix systems
function _glob(x) 
    if isabspath(x)
        p, rest = splitdir(x)
        glob(rest,p)
    else
        glob(x)
    end
end

open_mfdataset(g::AbstractString; kwargs...) = open_mfdataset(_glob(g); kwargs...)
open_mfdataset(g::Vector{<:AbstractString}; kwargs...) =
merge_datasets(map(i -> open_dataset(i; kwargs...), g))

function merge_new_axis(alldatasets, firstcube,var,mergedim)
    newdim = if !(typeof(DD.lookup(mergedim)) <: DD.NoLookup)
        DD.rebuild(mergedim, DD.val(mergedim))
    else
        DD.rebuild(mergedim, 1:length(alldatasets))
    end
    alldiskarrays = map(alldatasets) do ds
        ismissing(ds) ? missing : ds.cubes[var].data
    end
    newdims = (DD.dims(firstcube)...,newdim)
    s = ntuple(i->i==length(newdims) ? length(alldiskarrays) : 1, length(newdims))
    newda = DiskArrays.ConcatDiskArray(reshape(alldiskarrays,s...))
    YAXArray(newdims,newda,deepcopy(firstcube.properties))
end
function merge_existing_axis(alldatasets,firstcube,var,mergedim)
    allaxvals = map(ds->DD.dims(ds.cubes[var],mergedim).val,alldatasets)
    newaxvals = reduce(vcat,allaxvals)
    newdim = DD.rebuild(mergedim,newaxvals)
    alldiskarrays = map(ds->ds.cubes[var].data,alldatasets)
    istack = DD.dimnum(firstcube,mergedim)
    newshape = ntuple(i->i!=istack ? 1 : length(alldiskarrays),ndims(firstcube))
    newda = DiskArrays.ConcatDiskArray(reshape(alldiskarrays,newshape))
    newdims = Base.setindex(firstcube.axes,newdim,istack)
    YAXArray(newdims,newda,deepcopy(firstcube.properties))
end

"""
    open_mfdataset(files::DD.DimVector{<:AbstractString}; kwargs...)

Opens and concatenates a list of dataset paths along the dimension specified in `files`. 

This method can be used when the generic glob-based version of open_mfdataset fails
or is too slow. 
For example, to concatenate a list of annual NetCDF files along the `time` dimension, 
one can use:

````julia
files = ["1990.nc","1991.nc","1992.nc"]
open_mfdataset(DD.DimArray(files, YAX.time()))
````

alternatively, if the dimension to concatenate along does not exist yet, the 
dimension provided in the input arg is used:

````julia
files = ["a.nc", "b.nc", "c.nc"]
open_mfdataset(DD.DimArray(files, DD.Dim{:NewDim}(["a","b","c"])))
````
"""
function open_mfdataset(vec::DD.DimVector{<:Union{Missing,AbstractString}}; kwargs...)
    alldatasets = map(vec) do filename
        ismissing(filename) ? missing : open_dataset(filename;kwargs...)
    end
    fi = first(skipmissing(alldatasets))
    mergedim = DD.dims(alldatasets) |> only
    vars_to_merge = collect(keys(fi.cubes))
    ars = map(vars_to_merge) do var
        cfi = fi.cubes[var]
        mergedar = if DD.dims(cfi,mergedim) !== nothing
            merge_existing_axis(alldatasets,cfi,var,mergedim) 
        else
            merge_new_axis(alldatasets,cfi,var,mergedim)
        end
        var => mergedar
    end
    Dataset(;ars...)
end


"""
    open_dataset(g; skip_keys=(), driver=:all)

Open the dataset at `g` with the given `driver`.
The default driver will search for available drivers and tries to detect the useable driver from the filename extension.

### Keyword arguments

- `skip_keys` are passed as symbols, i.e., `skip_keys = (:a, :b)`
- `driver=:all`, common options are `:netcdf` or `:zarr`.

Example:

````julia
ds = open_dataset(f, driver=:zarr, skip_keys = (:c,))
````
"""
function open_dataset(g; skip_keys=(), driver = :all)
    str_skipkeys = string.(skip_keys)
    dsopen = YAXArrayBase.to_dataset(g, driver = driver)
    YAXArrayBase.open_dataset_handle(dsopen) do g 
        isempty(get_varnames(g)) && throw(ArgumentError("Group does not contain datasets."))
        dimlist = collectdims(g)
        dnames = string.(keys(dimlist))
        varlist = filter(get_varnames(g)) do vn
            upname = uppercase(vn)
            !in(vn, str_skipkeys) &&
            !occursin("BNDS", upname) &&
            !occursin("BOUNDS", upname) &&
            !any(i -> isequal(upname, uppercase(i)), dnames)
        end
        allcubes = OrderedDict{Symbol,YAXArray}()
        for vname in varlist
            vardims = get_var_dims(g, vname)
            iax = tuple(collect(dimlist[vd].ax for vd in vardims)...)
            offs = [dimlist[vd].offs for vd in vardims]
            subs = if all(iszero, offs)
                nothing
            else
                ntuple(i -> (offs[i]+1):(offs[i]+length(iax[i])), length(offs))
            end
            ar = get_var_handle(g, vname,persist=true)
            att = get_var_attrs(g, vname)
            if subs !== nothing
                ar = view(ar, subs...)
            end
            if !haskey(att, "name")
                att["name"] = vname
            end
            atts = propfromattr(att)
            if any(in(keys(atts)), ["missing_value", "scale_factor", "add_offset"])
                ar = CFDiskArray(ar, atts)
            end
            allcubes[Symbol(vname)] = YAXArray(iax, ar, atts, cleaner = CleanMe[])
        end
        gatts = YAXArrayBase.get_global_attrs(g)
        gatts = Dict{String,Any}(string(k)=>v for (k,v) in gatts)
        sdimlist = Dict(DD.name(v.ax) => v.ax for (k, v) in dimlist)
        Dataset(allcubes, sdimlist,gatts)
    end
end
#Base.getindex(x::Dataset; kwargs...) = subsetcube(x; kwargs...)
YAXDataset(; kwargs...) = Dataset(YAXArrays.YAXDefaults.cubedir[]; kwargs...)


to_array(ds::Dataset; joinname = "Variables") = Cube(ds;joinname)

"""
    Cube(ds::Dataset; joinname="Variables")

Construct a single YAXArray from the dataset `ds` by concatenating the cubes in the datset on the `joinname` dimension.
"""
function Cube(ds::Dataset; joinname = "Variables", target_type = nothing)

    dl = collect(keys(ds.axes))
    dls = string.(dl)
    length(ds.cubes) == 1 && return first(values(ds.cubes))
    # TODO This is an ugly workaround to merge cubes with different element types,
    # There should bde a more generic solution
    eltypes = map(eltype, values(ds.cubes))
    prom_type = target_type
    if prom_type === nothing
        prom_type = first(eltypes)
        for i in 2:length(eltypes)
            prom_type = promote_type(prom_type,eltypes[i])
            if !isconcretetype(Base.nonmissingtype(prom_type))
                wrongvar = collect(keys(ds.cubes))[i]
                throw(ArgumentError("Could not promote element types of cubes in dataset to a common concrete type, because of Variable $wrongvar"))
            end
        end
    end
    newkeys = Symbol[]
    for k in keys(ds.cubes)
        c = ds.cubes[k]
        if all(axn -> findAxis(axn, c) !== nothing, dls)
            push!(newkeys, k)
        end
    end
    if length(newkeys) == 1
        return ds.cubes[first(newkeys)]
    else
        varax = DD.rebuild(DD.name2dim(Symbol(joinname)), string.(newkeys))
        cubestomerge = map(newkeys) do k
            if eltype(ds.cubes[k]) <: prom_type
                ds.cubes[k]
            else
                map(Base.Fix1(convert,prom_type),ds.cubes[k])
            end
        end
        foreach(
        i -> haskey(i.properties, "name") && delete!(i.properties, "name"),
        cubestomerge,
        )
        return concatenatecubes(cubestomerge, varax)
    end
end

"""
Extract necessary information to create a YAXArrayBase dataset from a name and YAXArray pair
"""
function getarrayinfo(entry,backend)
    k,c = entry
    axlist = DD.dims(c)
    chunks = DiskArrays.eachchunk(c)
    cs = DiskArrays.approx_chunksize(chunks)
    co = DiskArrays.grid_offset(chunks)
    offs = Dict(Symbol(DD.name(ax))=>o for (ax,o) in zip(axlist,co))
    s = map(length, axlist) .+ co
    #Potentially create a view
    subs = if !all(iszero, co)
        ntuple(length(axlist)) do i
            (co[i]+1):s[i]
        end
    else
        nothing
    end
    T = eltype(c)
    hasmiss = T >: Missing
    attr = copy(c.properties)
    if hasmiss
        T = Base.nonmissingtype(T)
        if !haskey(attr, "missing_value")
            attr["missing_value"] = YAXArrayBase.defaultfillval(T)
        end
    end
    (name = string(k), t = T, chunks = cs,axes = axlist,attr = attr, subs = subs, require_CF = hasmiss, offs=offs)
end

"""
Extracts a YAXArray from a dataset handle that was just created from a arrayinfo
"""
function collectfromhandle(e,dshandle, cleaner)
    v = get_var_handle(dshandle, e.name)
    if !isnothing(e.subs)
        v = view(v, e.subs...)
    end
    if e.require_CF
        v = CFDiskArray(v, e.attr)
    end
    YAXArray(e.axes, v, propfromattr(e.attr), cleaner = cleaner)
end

function append_dataset(backend, path, ds, axdata, arrayinfo)
    dshandle = YAXArrayBase.to_dataset(backend,path,mode="w")
    existing_vars = YAXArrayBase.get_varnames(dshandle)
    for d in axdata
        if (d.name in existing_vars) && length(d.data) != length(YAXArrayBase.get_var_handle(dshandle,d.name))
            throw(ArgumentError("Can not write into existing dataset because of size mismatch in $(d.name)"))
        end
    end
    if any(i->i.name in existing_vars, arrayinfo)
        throw(ArgumentError("Variable already exists in dataset"))
    end
    dimstoadd = filter(ax->!in(ax.name,existing_vars),axdata)

    for d in dimstoadd
        add_var(dshandle, d.data, d.name, (d.name,), d.attrs)
    end
    for a in arrayinfo
        s = length.(a.axes)
        dn = string.(DD.name.(a.axes))
        add_var(dshandle, a.t, a.name, (s...,), dn, a.attr; chunksize = a.chunks)
    end

    dshandle
end

function copydataset!(diskds, ds;writefac=4.0, maxbuf=5e8)
    for (name,outds) in diskds.cubes
        inds = getproperty(ds,name)
        copy_diskarray(inds.data,outds.data;writefac, maxbuf)
    end
end

hasaxis(cube,k) = !isnothing(findAxis(k,cube))
function interpretchunks(chunks, ds)
    allaxes = collect(values(ds.axes))
    if chunks === nothing
        return NamedTuple()
    end
    if !isa(chunks,Union{NamedTuple,AbstractDict})
        chunks = Dict(k=>chunks for k in keys(ds.cubes))
    end
    allkeys = keys(chunks)
    if all(k->hasaxis(allaxes,k),allkeys)
        #Chunks are defined by axes
        Dict(k=>chunks for k in keys(ds.cubes))
    else
        #convert everything to Symbol keys
        Dict(Symbol(k)=>chunks[k] for k in allkeys)
    end
end


"""
    setchunks(c::Dataset,chunks)

Resets the chunks of all or a subset YAXArrays in the dataset and returns a new Dataset. Note that this will not change the chunking of the underlying data itself,
it will just make the data "look" like it had a different chunking. If you need a persistent on-disk representation
of this chunking, use `savedataset` on the resulting array. The `chunks` argument can take one of the following forms:

- a NamedTuple or AbstractDict mapping from variable name to a description of the desired variable chunks
- a NamedTuple or AbstractDict mapping from dimension name to a description of the desired variable chunks
- a description of the desired variable chunks applied to all members of the Dataset

where a description of the desired variable chunks can take one of the following forms:

- a `DiskArrays.GridChunks` object
- a tuple specifying the chunk size along each dimension
- an AbstractDict or NamedTuple mapping one or more axis names to chunk sizes
"""
function setchunks(ds::Dataset, chunks)
    newchunks = interpretchunks(chunks, ds)
    newds = deepcopy(ds)
    for k in keys(newds.cubes)
        if k in keys(newchunks)
            newds.cubes[k] = setchunks(newds.cubes[k],newchunks[k])
        end
    end
    newds
end

"""
    savedataset(ds::Dataset; path= "", persist=nothing, overwrite=false, append=false, skeleton=false, backend=:all, driver=backend, max_cache=5e8, writefac=4.0)

Saves a Dataset into a file at `path` with the format given by `driver`, i.e., `driver=:netcdf` or `driver=:zarr`.


!!! warning
    `overwrite=true`, deletes ALL your data and it will create a new file.
"""
function savedataset(
    ds::Dataset;
    path = "",
    persist = nothing,
    overwrite = false,
    append = false,
    skeleton=false,
    backend = :all,
    driver = backend,
    max_cache = 5e8,
    writefac=4.0,
    kwargs...)
    if persist === nothing
        persist = !isempty(path)
    end
    path = getsavefolder(path, persist)
    if ispath(path)
        if overwrite
            rm(path, recursive = true)
        elseif !append
            throw(ArgumentError("Path $path already exists. Consider setting `overwrite` or `append` keyword arguments"))
        end
    end
    backend = YAXArrayBase.backendfrompath(path;driver)

    cleaner = CleanMe[]
    persist || push!(cleaner, CleanMe(path, false))

    arrayinfo = map(c->getarrayinfo(c,backend),collect(ds.cubes))

    alloffsets = foldl(arrayinfo,init=Dict{Symbol,Int}()) do d1,d2
        mergewith!(d1,d2.offs) do x1,x2
            if x1 == x2
                x1
            else
                error("Can not store arrays with different chunk offsets in a single dataset")
            end
        end
    end

    axesall = values(ds.axes)
    chunkoffset = [alloffsets[k] for k in DD.name.(axesall)] # keys(ds.axes)
    axdata = arrayfromaxis.(axesall, chunkoffset)



    dshandle = if ispath(path)
        # We go into append mode
        append_dataset(backend, path, ds, axdata, arrayinfo)
    else
        YAXArrayBase.create_dataset(
            backend,
            path,
            ds.properties,
            string.(getproperty.(axdata,:name)),
            getproperty.(axdata,:data),
            getproperty.(axdata,:attrs),
            getproperty.(arrayinfo, :t),
            getproperty.(arrayinfo, :name),
            map(e -> string.(DD.name.(e.axes)), arrayinfo),
            getproperty.(arrayinfo, :attr),
            getproperty.(arrayinfo, :chunks);
            kwargs...
        )
    end
    #Generate back a Dataset from the generated structure on disk

    allnames = Symbol.(getproperty.(arrayinfo, :name))

    allcubes = map(e->collectfromhandle(e,dshandle,cleaner), arrayinfo)

    diskds = Dataset(OrderedDict(zip(allnames,allcubes)), copy(ds.axes),YAXArrayBase.get_global_attrs(dshandle))
    if !skeleton
        copydataset!(diskds, ds; maxbuf = max_cache, writefac)
    end
    return diskds
end


"""
    savecube(cube,name::String)

Save a [`YAXArray`](@ref) to the `path`.

# Extended Help

The keyword arguments are:

* `name`:
* `datasetaxis="Variables"` special treatment of a categorical axis that gets written into separate zarr arrays
* `max_cache`: The number of bits that are used as cache for the data handling.
* `backend`: The backend, that is used to save the data. Falls back to searching the backend according to the extension of the path.
* `driver`: The same setting as `backend`.
* `overwrite::Bool=false` overwrite cube if it already exists


"""
function savecube(
    c,
    path::AbstractString;
    layername = get(c.properties,"name","layer"),
    datasetaxis = "Variables",
    max_cache = 5e8,
    backend = :all,
    driver = backend,
    chunks = nothing,
    overwrite = false,
    append = false,
    skeleton=false,
    writefac=4.0,
    kwargs...
)
    if chunks !== nothing
        error("Setting chunks in savecube is not supported anymore. Rechunk using `setchunks` before saving. ")
    end
    
    ds = to_dataset(c; layername, datasetaxis)
    ds = savedataset(ds; path, max_cache, driver, overwrite, append,skeleton, writefac, kwargs...)
    Cube(ds, joinname = datasetaxis)
end


"""
    function createdataset(DS::Type,axlist; kwargs...)

Creates a new dataset with axes specified in `axlist`. Each axis must be a subtype
of `CubeAxis`. A new empty Zarr array will be created and can serve as a sink for
`mapCube` operations.

### Keyword arguments

* `path=""` location where the new cube is stored
* `T=Union{Float32,Missing}` data type of the target cube
* `chunksize = ntuple(i->length(axlist[i]),length(axlist))` chunk sizes of the array
* `chunkoffset = ntuple(i->0,length(axlist))` offsets of the chunks
* `persist::Bool=true` shall the disk data be garbage-collected when the cube goes out of scope?
* `overwrite::Bool=false` overwrite cube if it already exists
* `properties=Dict{String,Any}()` additional cube properties
* `globalproperties=Dict{String,Any}` global attributes to be added to the dataset
* `fillvalue= T>:Missing ? defaultfillval(Base.nonmissingtype(T)) : nothing` fill value
* `datasetaxis="Variables"` special treatment of a categorical axis that gets written into separate zarr arrays
* `layername="layer"` Fallback name of the variable stored in the dataset if no `datasetaxis` is found
"""
function createdataset(
    DS,
    axlist;
    path = "",
    persist = nothing,
    T = Union{Float32,Missing},
    chunksize = ntuple(i -> length(axlist[i]), length(axlist)),
    chunkoffset = ntuple(i -> 0, length(axlist)),
    overwrite::Bool = false,
    properties = Dict{String,Any}(),
    globalproperties = Dict{String,Any}(),
    datasetaxis = "Variables",
    layername = get(properties, "name", "layer"),
    kwargs...,
)
    if persist === nothing
        persist = !isempty(path)
    end
    attr = Dict{String,Any}(properties)
    path = getsavefolder(path, persist)
    check_overwrite(path, overwrite)
    splice_generic(x::AbstractArray, i) = [x[1:(i-1)]; x[(i+1:end)]]
    splice_generic(x::Tuple, i) = (x[1:(i-1)]..., x[(i+1:end)]...)
    finalperm = nothing
    idatasetax = datasetaxis === nothing ? nothing : findAxis(datasetaxis, axlist)
    if idatasetax !== nothing
        groupaxis = axlist[idatasetax]
        axlist = splice_generic(axlist, idatasetax)
        chunksize = splice_generic(chunksize, idatasetax)
        chunkoffset = splice_generic(chunkoffset, idatasetax)
        finalperm =
            ((1:idatasetax-1)..., length(axlist) + 1, (idatasetax:length(axlist))...)
        else
            groupaxis = nothing
        end
        axdata = arrayfromaxis.(axlist, chunkoffset)
        s = map(length, axlist) .+ chunkoffset
        subs = nothing
        #Potentially create a view
        if !all(iszero, chunkoffset)
            subs = ntuple(length(axlist)) do i
                (chunkoffset[i]+1):(length(axlist[i])+chunkoffset[i])
            end
        end
        if groupaxis === nothing
            cubenames = [layername]
        else
            cubenames = DD.lookup(groupaxis)
        end
        cleaner = CleanMe[]
        persist || push!(cleaner, CleanMe(path, false))
        hasmissings =  (T >: Missing)
        S = Base.nonmissingtype(T)
        if hasmissings && !haskey(attr, "missing_value")
                attr["missing_value"] = YAXArrayBase.defaultfillval(S)
        end
        dshandle = YAXArrayBase.create_dataset(
        DS,
        path,
        globalproperties,
        string.(getproperty.(axdata,:name)),
        getproperty.(axdata,:data),
        getproperty.(axdata,:attrs),
        fill(S, length(cubenames)),
        cubenames,
        fill(string.(getproperty.(axdata,:name)),length(cubenames)),
        fill(attr,length(cubenames)),
        fill(chunksize, length(cubenames));
        kwargs...
        )
        #This generates the YAXArrays
        allcubes = map(cubenames) do cn
            v = get_var_handle(dshandle, cn)
            if !isnothing(subs)
                v = view(v, subs...)
            end
            if hasmissings
                v = CFDiskArray(v, attr)
            end
            YAXArray((axlist...,), v, propfromattr(attr), cleaner = cleaner)
        end
        if groupaxis === nothing
            return allcubes[1], allcubes[1]
        else
            cube = concatenatecubes(allcubes, groupaxis)
            return permutedims(cube, finalperm), cube
        end
    end

    function getsavefolder(name, persist)
        if isempty(name)
            name = persist ? [splitpath(tempname())[end]] : splitpath(tempname())[2:end]
            joinpath(YAXDefaults.workdir[], name...)
        else
            (occursin("/", name) || occursin("\\", name)) ? name :
            joinpath(YAXDefaults.workdir[], name)
        end
    end

    function check_overwrite(newfolder, overwrite)
        if isdir(newfolder) || isfile(newfolder)
            if overwrite
                rm(newfolder, recursive = true)
            else
                error(
                "$(newfolder) already exists, please pick another name or use `overwrite=true`",
                )
            end
        end
    end

    function arrayfromaxis(ax::DD.Dimension, offs)
        data, attr = dataattfromaxis(ax, offs,eltype(ax))
        attr["_ARRAY_OFFSET"] = offs
        return (name = string(DD.name(ax)), data = data, attrs = attr)
    end

    prependrange(r::AbstractRange, n) =
    n == 0 ? r : range(first(r) - n * step(r), last(r), length = n + length(r))
    function prependrange(r::AbstractVector, n)
        if n == 0
            return r
        else
            step = r[2] - r[1]
            first = r[1] - step * n
            last = r[1] - step
            radd = range(first, last, length = n)
            return [radd; r]
        end
    end

    defaultcal(::Type{<:TimeType}) = "standard"
    defaultcal(::Type{<:DateTimeNoLeap}) = "noleap"
    defaultcal(::Type{<:DateTimeAllLeap}) = "allleap"
    defaultcal(::Type{<:DateTime360Day}) = "360_day"

    datetodatetime(vals::AbstractArray{<:Date}) = DateTime.(vals)
    datetodatetime(vals) = vals
    toaxistype(x) = x
    toaxistype(x::Array{<:AbstractString}) = string.(x)
    toaxistype(x::Array{String}) = x

    function dataattfromaxis(ax::DD.Dimension, n, _)
        prependrange(toaxistype(DD.lookup(ax)), n), Dict{String,Any}()
    end
    middle(x::DD.IntervalSets.Interval) = x.left + half(x.right-x.left)
    half(x::Period) = int_half(x)
    half(x::Integer) = int_half(x)
    half(x) = x/2
    int_half(x) = x÷2
    function dataattfromaxis(ax::DD.Dimension, n, T::Type{<:DD.IntervalSets.Interval})
        newdim = DD.rebuild(ax,middle.(ax.val))
        dataattfromaxis(newdim,n,eltype(newdim))
    end
    # function dataattfromaxis(ax::CubeAxis,n)
    #     prependrange(1:length(ax.values),n), Dict{String,Any}("_ARRAYVALUES"=>collect(ax.values))
    # end
    function dataattfromaxis(ax::DD.Dimension, n, T::Type{<:TimeType})
        data = timeencode(datetodatetime(DD.lookup(ax)), "days since 1980-01-01", defaultcal(T))
        prependrange(data, n),
        Dict{String,Any}("units" => "days since 1980-01-01", "calendar" => defaultcal(T))
    end

    #The good old Cube function:
    Cube(s::String; kwargs...) = Cube(open_dataset(s); kwargs...)
    function Cube(; kwargs...)
        if !isempty(YAXArrays.YAXDefaults.cubedir[])
            Cube(YAXArrays.YAXDefaults.cubedir[]; kwargs...)
        else
            error("A path should be specified")
        end
    end

    #Defining joins of Datasets
    abstract type AxisJoin end
    struct AllEqual <: AxisJoin
        ax::Any
    end
    struct SortedRanges <: AxisJoin
        axlist::Any
        perm::Any
    end
    blocksize(x::AllEqual) = 1
    blocksize(x::SortedRanges) = length(x.axlist)
    getperminds(x::AllEqual) = 1:1
    getperminds(x::SortedRanges) = x.perm
    wholeax(x::AllEqual) = x.ax
    wholeax(x::SortedRanges) = reduce(vcat, x.axlist[x.perm])
    struct NewDim <: AxisJoin
        newax::Any
    end
    #Test for a range of categorical axes how to concatenate them
    function analyse_axjoin_ranges(dimvallist)
        firstax = first(dimvallist)
        if all(isequal(firstax), dimvallist)
            return AllEqual(firstax)
        end
        revorder = if all(issorted, dimvallist)
            false
        elseif all(i -> issorted(i, rev = true), dimvallist)
            true
        else
            error("Dimension values are not sorted")
        end
        function ltfunc(ax1, ax2)
            min1, max1 = extrema(ax1)
            min2, max2 = extrema(ax2)
            if max1 < min2
                return true
            elseif min1 > max2
                return false
            else
                error("Dimension ranges overlap")
            end
        end
        sp = sortperm(dimvallist, rev = revorder, lt = ltfunc)
        SortedRanges(dimvallist, sp)
    end
    using YAXArrayBase: YAXArrayBase, getdata, getattributes, yaxcreate
    function create_mergedict(dimvallist)
        allmerges = Dict{Symbol,Any}()

        for (axn, dimvals) in dimvallist
            iscont = iscontdimval.(dimvals)
            if all(iscont)
                allmerges[axn] = analyse_axjoin_ranges(dimvals)
            elseif any(iscont)
                error("Mix of continous and non-continous values")
            else
                allmerges[axn] = analyse_axjoin_categorical(dimvals)
            end
        end
        allmerges
    end
    function merge_datasets(dslist)
        if length(dslist) == 1
            return dslist[1]
        end
        allaxnames = counter(Symbol)
        for ds in dslist, k in keys(ds.axes)
            push!(allaxnames, k)
        end
        dimvallist = Dict(ax => map(i -> DD.lookup(i.axes[ax]), dslist) for ax in keys(allaxnames))
        allmerges = create_mergedict(dimvallist)
        repvars = counter(Symbol)
        for ds in dslist, v in keys(ds.cubes)
            push!(repvars, v)
        end
        tomergevars = filter(i -> i[2] == length(dslist), repvars)
        mergedvars = Dict{Symbol,Any}()
        for v in keys(tomergevars)
            dn = YAXArrayBase.dimnames(first(dslist)[v])
            howmerge = getindex.(Ref(allmerges), dn)
            sizeblockar = map(blocksize, howmerge)
            perminds = map(getperminds, howmerge)
            @assert length(dslist) == prod(sizeblockar)
            vcol = map(i -> getdata(i[v]), dslist)
            allatts =
            mapreduce(i -> getattributes(i[v]), merge, dslist, init = Dict{String,Any}())
            aa = [vcol[i] for (i, _) in enumerate(Iterators.product(perminds...))]
            dvals = map(wholeax, howmerge)
            mergedvars[v] = yaxcreate(YAXArray, ConcatDiskArray(aa), dn, dvals, allatts)
        end
        Dataset(; mergedvars...)
    end


end
