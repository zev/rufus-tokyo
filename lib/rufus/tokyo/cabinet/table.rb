#
#--
# Copyright (c) 2009, John Mettraux, jmettraux@gmail.com
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#++
#

#
# "made in Japan"
#
# jmettraux@gmail.com
#

module Rufus
  module Tokyo

    #
    # Methods for setting up / tuning a Cabinet.
    #
    # Gets included into Table.
    #
    module CabinetConfig

      protected

      #
      # Given a path, a hash of parameters and a suffix,
      #
      # a) makes sure that the path has the given suffix or raises an exception
      # b) gathers params found in the path (#) or in params
      # c) determines the config as set by the parameters
      #
      def determine_conf (path, params, suffix)

        if path.index('#')

          ss = path.split('#')
          path = ss.shift

          ss.each { |p| pp = p.split('='); params[pp[0]] = pp[1] }
        end

        raise "path '#{path}' must be suffixed with #{suffix}" \
          unless path[-suffix.length..-1] == suffix

        params = params.inject({}) { |h, (k, v)| h[k.to_sym] = v; h }

        conf = {
          :params => params,
          :path => path,
          :mode => determine_open_mode(params),
          :mutex => (params[:mutex].to_s == 'true'),
          #:indexes => params[:idx] || params[:indexes],
          :xmsiz => (params[:xmsiz] || 67108864).to_i
        }
        conf.merge!(determine_tuning_values(params))
        conf.merge(determine_cache_values(params))
      end

      def determine_open_mode (params) #:nodoc#

        mode = params[:mode].to_s
        mode = 'wc' if mode.size < 1

        {
          'r' => (1 << 0), # open as a reader
          'w' => (1 << 1), # open as a writer
          'c' => (1 << 2), # writer creating
          't' => (1 << 3), # writer truncating
          'e' => (1 << 4), # open without locking
          'f' => (1 << 5), # lock without blocking
          's' => (1 << 6), # synchronize every transaction (tctdb.h)

        }.inject(0) { |r, (c, v)|

          r = r | v if mode.index(c); r
        }
      end

      def determine_tuning_values (params) #:nodoc#

        bnum = (params[:bnum] || 131071).to_i
        apow = (params[:apow] || 4).to_i
        fpow = (params[:fpow] || 10).to_i

        o = params[:opts] || ''
        o = {
          'l' => 1 << 0, # large
          'd' => 1 << 1, # deflate
          'b' => 1 << 2, # bzip2
          't' => 1 << 3, # tcbs
          'x' => 1 << 4
        }.inject(0) { |i, (k, v)| i = i | v if o.index(k); i }

        { :bnum => bnum, :apow => apow, :fpow => fpow, :opts => o }
      end

      def determine_cache_values (params) #:nodoc#

        {
          :rcnum => params[:rcnum].to_i,
          :lcnum => (params[:lcnum] || 2048).to_i,
          :ncnum => (params[:ncnum] || 512).to_i
        }
      end
    end

    #
    # A 'table' a table database.
    #
    #   http://alpha.mixi.co.jp/blog/?p=290
    #   http://tokyocabinet.sourceforge.net/spex-en.html#tctdbapi
    #
    # A short example :
    #
    #   require 'rubygems'
    #   require 'rufus/tokyo/cabinet/table'
    #
    #   t = Rufus::Tokyo::Table.new('table.tdb', :create, :write)
    #     # '.tdb' suffix is a must
    #
    #   t['pk0'] = { 'name' => 'alfred', 'age' => '22' }
    #   t['pk1'] = { 'name' => 'bob', 'age' => '18' }
    #   t['pk2'] = { 'name' => 'charly', 'age' => '45' }
    #   t['pk3'] = { 'name' => 'doug', 'age' => '77' }
    #   t['pk4'] = { 'name' => 'ephrem', 'age' => '32' }
    #
    #   p t.query { |q|
    #     q.add_condition 'age', :numge, '32'
    #     q.order_by 'age'
    #     q.limit 2
    #   }
    #     # => [ {"name"=>"ephrem", :pk=>"pk4", "age"=>"32"},
    #     #      {"name"=>"charly", :pk=>"pk2", "age"=>"45"} ]
    #
    #   t.close
    #
    class Table

      include HashMethods
      include CabinetConfig

      #
      # Creates a Table instance (creates or opens it depending on the args)
      #
      # For example,
      #
      #   t = Rufus::Tokyo::Table.new('table.tdb')
      #     # '.tdb' suffix is a must
      #
      # will create the table.tdb (or simply open it if already present)
      # and make sure we have write access to it.
      #
      # == parameters
      #
      # Parameters can be set in the path or via the optional params hash (like
      # in Rufus::Tokyo::Cabinet)
      #
      #   * :mode    a set of chars ('r'ead, 'w'rite, 'c'reate, 't'runcate,
      #              'e' non locking, 'f' non blocking lock), default is 'wc'
      #   * :opts    a set of chars ('l'arge, 'd'eflate, 'b'zip2, 't'cbs)
      #              (usually empty or something like 'ld' or 'lb')
      #
      #   * :bnum    number of elements of the bucket array
      #   * :apow    size of record alignment by power of 2 (defaults to 4)
      #   * :fpow    maximum number of elements of the free block pool by
      #              power of 2 (defaults to 10)
      #   * :mutex   when set to true, makes sure only 1 thread at a time
      #              accesses the table (well, Ruby, global thread lock, ...)
      #
      #   * :rcnum   specifies the maximum number of records to be cached.
      #              If it is not more than 0, the record cache is disabled.
      #              It is disabled by default.
      #   * :lcnum   specifies the maximum number of leaf nodes to be cached.
      #              If it is not more than 0, the default value is specified.
      #              The default value is 2048.
      #   * :ncnum   specifies the maximum number of non-leaf nodes to be
      #              cached. If it is not more than 0, the default value is
      #              specified. The default value is 512.
      #
      #   * :xmsiz   specifies the size of the extra mapped memory. If it is
      #              not more than 0, the extra mapped memory is disabled.
      #              The default size is 67108864.
      #
      # Some examples :
      #
      #   t = Rufus::Tokyo::Table.new('table.tdb')
      #   t = Rufus::Tokyo::Table.new('table.tdb#mode=r')
      #   t = Rufus::Tokyo::Table.new('table.tdb', :mode => 'r')
      #   t = Rufus::Tokyo::Table.new('table.tdb#opts=ld#mode=r')
      #   t = Rufus::Tokyo::Table.new('table.tdb', :opts => 'ld', :mode => 'r')
      #
      def initialize (path, params={})

        conf = determine_conf(path, params, '.tdb')

        @db = lib.tctdbnew

        #
        # tune table

        libcall(:tctdbsetmutex) if conf[:mutex]

        libcall(:tctdbtune, conf[:bnum], conf[:apow], conf[:fpow], conf[:opts])

        # TODO : set indexes here... well, there is already #set_index
        #conf[:indexes]...

        libcall(:tctdbsetcache, conf[:rcnum], conf[:lcnum], conf[:ncnum])

        libcall(:tctdbsetxmsiz, conf[:xmsiz])

        #
        # open table

        libcall(:tctdbopen, conf[:path], conf[:mode])
      end

      #
      # using the cabinet lib
      #
      def lib
        CabinetLib
      end

      #
      # Closes the table (and frees the datastructure allocated for it),
      # returns true in case of success.
      #
      def close
        result = lib.tab_close(@db)
        lib.tab_del(@db)
        (result == 1)
      end

      #
      # Generates a unique id (in the context of this Table instance)
      #
      def generate_unique_id
        lib.tab_genuid(@db)
      end
      alias :genuid :generate_unique_id

      INDEX_TYPES = {
        :lexical => 0,
        :decimal => 1,
        :void => 9999,
        :remove => 9999,
        :keep => 1 << 24
      }

      #
      # Sets an index on a column of the table.
      #
      # Types maybe be :lexical or :decimal, use :keep to "add" and
      # :remove (or :void) to "remove" an index.
      #
      # If column_name is :pk or "", the index will be set on the primary key.
      #
      # Returns true in case of success.
      #
      def set_index (column_name, *types)

        column_name = '' if column_name == :pk

        i = types.inject(0) { |i, t| i = i & INDEX_TYPES[t]; i }

        (lib.tab_setindex(@db, column_name, i) == 1)
      end

      #
      # Inserts a record in the table db
      #
      #   table['pk0'] = [ 'name', 'fred', 'age', '45' ]
      #   table['pk1'] = { 'name' => 'jeff', 'age' => '46' }
      #
      # Accepts both a hash or an array (expects the array to be of the
      # form [ key, value, key, value, ... ] else it will raise
      # an ArgumentError)
      #
      def []= (pk, h_or_a)

        m = Rufus::Tokyo::Map[h_or_a]

        r = lib.tab_put(@db, pk, CabinetLib.strlen(pk), m.pointer)

        m.free

        (r == 1) || raise_error

        h_or_a
      end

      #
      # Removes an entry in the table
      #
      # (might raise an error if the delete itself failed, but returns nil
      # if there was no entry for the given key)
      #
      def delete (k)
        v = self[k]
        return nil unless v
        libcall(:tab_out, k, CabinetLib.strlen(k))
        v
      end

      #
      # Removes all records in this table database
      #
      def clear
        libcall(:tab_vanish)
      end

      #
      # Returns an array of all the primary keys in the table
      #
      # With no options given, this method will return all the keys (strings)
      # in a Ruby array.
      #
      #   :prefix --> returns only the keys who match a given string prefix
      #
      #   :limit --> returns a limited number of keys
      #
      #   :native --> returns an instance of Rufus::Tokyo::List instead of
      #     a Ruby Hash, you have to call #free on that List when done with it !
      #     Else you're exposing yourself to a memory leak.
      #
      def keys (options={})

        if pref = options[:prefix]

          l = lib.tab_fwmkeys2(@db, pref, options[:limit] || -1)
          l = Rufus::Tokyo::List.new(l)
          options[:native] ? l : l.release

        else

          limit = options[:limit] || -1
          limit = nil if limit < 1

          l = options[:native] ? Rufus::Tokyo::List.new : []

          lib.tab_iterinit(@db)

          while (k = (lib.tab_iternext2(@db) rescue nil))
            break if limit and l.size >= limit
            l << k
          end

          l
        end
      end

      #
      # Returns the number of records in this table db
      #
      def size
        lib.tab_rnum(@db)
      end

      #
      # Prepares a query instance (block is optional)
      #
      def prepare_query (&block)
        q = TableQuery.new(self)
        block.call(q) if block
        q
      end

      #
      # Prepares and runs a query, returns a ResultSet instance
      # (takes care of freeing the query structure)
      #
      def do_query (&block)
        q = prepare_query(&block)
        rs = q.run
        q.free
        rs
      end

      #
      # Prepares and runs a query, returns an array of hashes (all Ruby)
      # (takes care of freeing the query and the result set structures)
      #
      def query (&block)
        rs = do_query(&block)
        a = rs.to_a
        rs.free
        a
      end

      #
      # Transaction in a block.
      #
      #   table.transaction do
      #     table['pk0'] => { 'name' => 'Fred', 'age' => '40' }
      #     table['pk1'] => { 'name' => 'Brooke', 'age' => '76' }
      #     table.abort if weather.bad?
      #   end
      #
      # If an error or an abort is trigger withing the transaction, it's rolled
      # back. If the block executes successfully, it gets commited.
      #
      def transaction

        return unless block_given?

        begin
          tranbegin
          yield
          trancommit
        rescue Exception => e
          tranabort
        end
      end

      #
      # Aborts the enclosing transaction
      #
      # See #transaction
      #
      def abort
        raise "abort transaction !"
      end

      #
      # Warning : this method is low-level, you probably only need
      # to use #transaction and a block.
      #
      # Direct call for 'transaction begin'.
      #
      def tranbegin
        libcall(:tctdbtranbegin)
      end

      #
      # Warning : this method is low-level, you probably only need
      # to use #transaction and a block.
      #
      # Direct call for 'transaction commit'.
      #
      def trancommit
        libcall(:tctdbtrancommit)
      end

      #
      # Warning : this method is low-level, you probably only need
      # to use #transaction and a block.
      #
      # Direct call for 'transaction abort'.
      #
      def tranabort
        libcall(:tctdbtranabort)
      end

      #
      # Returns the actual pointer to the Tokyo Cabinet table
      #
      def pointer
        @db
      end

      protected

      #
      # Returns the value (as a Ruby Hash) else nil
      #
      # (the actual #[] method is provided by HashMethods)
      #
      def get (k)
        m = lib.tab_get(@db, k, CabinetLib.strlen(k))
        return nil if m.address == 0 # :( too bad, but it works
        Map.to_h(m) # which frees the map
      end

      def libcall (lib_method, *args)

        #(lib.send(lib_method, @db, *args) == 1) or raise_error
          # stack level too deep with JRuby 1.1.6 :(

        (eval(%{ lib.#{lib_method}(@db, *args) }) == 1) or raise_error
          # works with JRuby 1.1.6
      end

      #
      # Obviously something got wrong, let's ask the db about it and raise
      # a TokyoError
      #
      def raise_error

        err_code = lib.tab_ecode(@db)
        err_msg = lib.tab_errmsg(err_code)

        raise TokyoError, "(err #{err_code}) #{err_msg}"
      end
    end

    #
    # A query on a Tokyo Cabinet table db
    #
    class TableQuery

      OPERATORS = {

        # strings...

        :streq => 0, # string equality
        :eq => 0,
        :eql => 0,
        :equals => 0,

        :strinc => 1, # string include
        :inc => 1, # string include
        :includes => 1, # string include

        :strbw => 2, # string begins with
        :bw => 2,
        :starts_with => 2,
        :strew => 3, # string ends with
        :ew => 3,
        :ends_with => 3,

        :strand => 4, # string which include all the tokens in the given exp
        :and => 4,

        :stror => 5, # string which include at least one of the tokens
        :or => 5,

        :stroreq => 6, # string which is equal to at least one token

        :strorrx => 7, # string which matches the given regex
        :regex => 7,
        :matches => 7,

        # numbers...

        :numeq => 8, # equal
        :numequals => 8,
        :numgt => 9, # greater than
        :gt => 9,
        :numge => 10, # greater or equal
        :ge => 10,
        :gte => 10,
        :numlt => 11, # greater or equal
        :lt => 11,
        :numle => 12, # greater or equal
        :le => 12,
        :lte => 12,
        :numbt => 13, # a number between two tokens in the given exp
        :bt => 13,
        :between => 13,

        :numoreq => 14 # number which is equal to at least one token
      }

      TDBQCNEGATE = 1 << 24
      TDBQCNOIDX = 1 << 25

      DIRECTIONS = {
        :strasc => 0,
        :strdesc => 1,
        :asc => 0,
        :desc => 1,
        :numasc => 2,
        :numdesc => 3
      }

      #
      # Creates a query for a given Rufus::Tokyo::Table
      #
      # Queries are usually created via the #query (#prepare_query #do_query)
      # of the Table instance.
      #
      # Methods of interest here are :
      #
      #   * #add (or #add_condition)
      #   * #order_by
      #   * #limit
      #
      # also
      #
      #   * #pk_only
      #   * #no_pk
      #
      def initialize (table)
        @table = table
        @query = @table.lib.qry_new(@table.pointer)
        @opts = {}
      end

      def lib
        @table.lib
      end

      #
      # Adds a condition
      #
      #   table.query { |q|
      #     q.add 'name', :equals, 'Oppenheimer'
      #     q.add 'age', :numgt, 35
      #   }
      #
      # Understood 'operators' :
      #
      #   :streq # string equality
      #   :eq
      #   :eql
      #   :equals
      #
      #   :strinc # string include
      #   :inc # string include
      #   :includes # string include
      #
      #   :strbw # string begins with
      #   :bw
      #   :starts_with
      #   :strew # string ends with
      #   :ew
      #   :ends_with
      #
      #   :strand # string which include all the tokens in the given exp
      #   :and
      #
      #   :stror # string which include at least one of the tokens
      #   :or
      #
      #   :stroreq # string which is equal to at least one token
      #
      #   :strorrx # string which matches the given regex
      #   :regex
      #   :matches
      #
      #   # numbers...
      #
      #   :numeq # equal
      #   :numequals
      #   :numgt # greater than
      #   :gt
      #   :numge # greater or equal
      #   :ge
      #   :gte
      #   :numlt # greater or equal
      #   :lt
      #   :numle # greater or equal
      #   :le
      #   :lte
      #   :numbt # a number between two tokens in the given exp
      #   :bt
      #   :between
      #
      #   :numoreq # number which is equal to at least one token
      #
      def add (colname, operator, val, affirmative=true, no_index=true)
        op = operator.is_a?(Fixnum) ? operator : OPERATORS[operator]
        op = op | TDBQCNEGATE unless affirmative
        op = op | TDBQCNOIDX if no_index
        lib.qry_addcond(@query, colname, op, val)
      end
      alias :add_condition :add

      #
      # Sets the max number of records to return for this query.
      #
      # (sorry no 'offset' as of now)
      #
      def limit (i)
        lib.qry_setmax(@query, i)
      end

      #
      # Sets the sort order for the result of the query
      #
      # The 'direction' may be :
      #
      #   :strasc # string ascending
      #   :strdesc
      #   :asc # string ascending
      #   :desc
      #   :numasc # number ascending
      #   :numdesc
      #
      def order_by (colname, direction=:strasc)
        lib.qry_setorder(@query, colname, DIRECTIONS[direction])
      end

      #
      # When set to true, only the primary keys of the matching records will
      # be returned.
      #
      def pk_only (on=true)
        @opts[:pk_only] = on
      end

      #
      # When set to true, the :pk (primary key) is not inserted in the record
      # (hashes) returned
      #
      def no_pk (on=true)
        @opts[:no_pk] = on
      end

      #
      # Runs this query (returns a TableResultSet instance)
      #
      def run
        TableResultSet.new(@table, lib.qry_search(@query), @opts)
      end

      #
      # Frees this data structure
      #
      def free
        lib.qry_del(@query)
        @query = nil
      end

      alias :close :free
      alias :destroy :free
    end

    #
    # The thing queries return
    #
    class TableResultSet
      include Enumerable

      def initialize (table, list_pointer, query_opts)
        @table = table
        @list = list_pointer
        @opts = query_opts
      end

      #
      # Returns the count of element in this result set
      #
      def size
        CabinetLib.tclistnum(@list)
      end

      alias :length :size

      #
      # The classical each
      #
      def each
        (0..size-1).each do |i|
          pk = CabinetLib.tclistval2(@list, i)
          if @opts[:pk_only]
            yield(pk)
          else
            val = @table[pk]
            val[:pk] = pk unless @opts[:no_pk]
            yield(val)
          end
        end
      end

      #
      # Returns an array of hashes
      #
      def to_a
        collect { |m| m }
      end

      #
      # Frees this query (the underlying Tokyo Cabinet list structure)
      #
      def free
        CabinetLib.tclistdel(@list)
        @list = nil
      end

      alias :close :free
      alias :destroy :free
    end

  end
end
