RSpec.describe "Transactions" do
  let(:transaction) {
    Class.new do
      include Dry::Transaction(container: Test::Container)
        map :process
        step :verify
        try :validate, catch: Test::NotValidError
        tee :persist
    end.new(**dependencies)
  }

  let(:dependencies) { {} }

  before do
    Test::NotValidError = Class.new(StandardError)
    Test::DB = []
    Test::Container = {
      process:  -> input { {name: input["name"], email: input["email"]} },
      verify:   -> input { Right(input) },
      validate: -> input { input[:email].nil? ? raise(Test::NotValidError, "email required") : input },
      persist:  -> input { Test::DB << input and true },
    }
  end

  context "successful" do
    let(:input) { {"name" => "Jane", "email" => "jane@doe.com"} }

    it "calls the operations" do
      transaction.call(input)
      expect(Test::DB).to include(name: "Jane", email: "jane@doe.com")
    end

    it "returns a success" do
      expect(transaction.call(input)).to be_a Dry::Monads::Either::Right
    end

    it "wraps the result of the final operation" do
      expect(transaction.call(input).value).to eq(name: "Jane", email: "jane@doe.com")
    end

    it "can be called multiple times to the same effect" do
      transaction.call(input)
      transaction.call(input)

      expect(Test::DB[0]).to eq(name: "Jane", email: "jane@doe.com")
      expect(Test::DB[1]).to eq(name: "Jane", email: "jane@doe.com")
    end

    it "supports matching on success" do
      results = []

      transaction.call(input) do |m|
        m.success do |value|
          results << "success for #{value[:email]}"
        end

        m.failure { }
      end

      expect(results.first).to eq "success for jane@doe.com"
    end
  end

  context "different step names" do
    before do
      module Test
        ContainerNames = {
          process_step:  -> input { {name: input["name"], email: input["email"]} },
          verify_step:   -> input { Dry::Monads.Right(input) },
          persist_step:  -> input { Test::DB << input and true },
        }
      end
    end

    let(:transaction) {
      Class.new do
        include Dry::Transaction(container: Test::ContainerNames)

        map :process, with: :process_step
        step :verify, with: :verify_step
        tee :persist, with: :persist_step
      end.new(**dependencies)
    }

    it "supports steps using differently named container operations" do
      transaction.call("name" => "Jane", "email" => "jane@doe.com")
      expect(Test::DB).to include(name: "Jane", email: "jane@doe.com")
    end
  end

  describe "operation injection" do
    let(:transaction) {
      Class.new do
        include Dry::Transaction(container: Test::Container)
          map :process
          step :verify_step, with: :verify
          tee :persist
      end.new(**dependencies)
    }

    let(:dependencies) {
      {verify_step: -> input { Dry::Monads.Right(input.merge(foo: :bar)) }}
    }

    it "calls injected operations" do
      transaction.call("name" => "Jane", "email" => "jane@doe.com")

      expect(Test::DB).to include(name: "Jane", email: "jane@doe.com", foo: :bar)
    end
  end

  context "wrapping operations with local methods" do
    let(:transaction) do
      Class.new do
        include Dry::Transaction(container: Test::Container)

        map :process, with: :process
        step :verify, with: :verify
        tee :persist, with: :persist

        def verify(input)
          new_input = input.merge(greeting: "hello!")
          super(new_input)
        end
      end.new(**dependencies)
    end

    let(:dependencies) { {} }

    it "allows local methods to run operations via super" do
      transaction.call("name" => "Jane", "email" => "jane@doe.com")

      expect(Test::DB).to include(name: "Jane", email: "jane@doe.com", greeting: "hello!")
    end
  end

  context "local step definition" do
    let(:transaction) do
      Class.new do
        include Dry::Transaction(container: Test::Container)

        map :process, with: :process
        step :verify
        tee :persist, with: :persist

        def verify(input)
          Right(input.keys)
        end
      end.new
    end

    it "execute step only defined as local method" do
      transaction.call("name" => "Jane", "email" => "jane@doe.com")

      expect(Test::DB).to include([:name, :email])
    end
  end

  context "all steps are local methods" do
    let(:transaction) do
      Class.new do
        include Dry::Transaction

        map :process
        step :verify
        tee :persist

        def process(input)
          input.to_a
        end

        def verify(input)
          Dry::Monads.Right(input)
        end

        def persist(input)
          Test::DB << input and true
        end
      end.new
    end

    it "executes succesfully" do
      transaction.call("name" => "Jane", "email" => "jane@doe.com")
      expect(Test::DB).to include([["name", "Jane"], ["email", "jane@doe.com"]])
    end
  end

  context "failed in a try step" do
    let(:input) { {"name" => "Jane"} }

    it "does not run subsequent operations" do
      transaction.call(input)
      expect(Test::DB).to be_empty
    end

    it "returns a failure" do
      expect(transaction.call(input)).to be_a Dry::Monads::Either::Left
    end

    it "wraps the result of the failing operation" do
      expect(transaction.call(input).value).to be_a Test::NotValidError
    end

    it "supports matching on failure" do
      results = []

      transaction.call(input) do |m|
        m.success { }

        m.failure do |value|
          results << "Failed: #{value}"
        end
      end

      expect(results.first).to eq "Failed: email required"
    end

    it "supports matching on specific step failures" do
      results = []

      transaction.call(input) do |m|
        m.success { }

        m.failure :validate do |value|
          results << "Validation failure: #{value}"
        end
      end

      expect(results.first).to eq "Validation failure: email required"
    end

    it "supports matching on un-named step failures" do
      results = []

      transaction.call(input) do |m|
        m.success { }

        m.failure :some_other_step do |value|
          results << "Some other step failure"
        end

        m.failure do |value|
          results << "Catch-all failure: #{value}"
        end
      end

      expect(results.first).to eq "Catch-all failure: email required"
    end
  end

  context "failed in a raw step" do
    let(:input) { {"name" => "Jane", "email" => "jane@doe.com"} }

    before do
      Test::Container[:verify] = -> input { Left("raw failure") }
    end

    it "does not run subsequent operations" do
      transaction.call(input)
      expect(Test::DB).to be_empty
    end

    it "returns a failure" do
      expect(transaction.call(input)).to be_a Dry::Monads::Either::Left
    end

    it "returns the failing value from the operation" do
      expect(transaction.call(input).value).to eq "raw failure"
    end

    it "returns an object that quacks like expected" do
      result = transaction.call(input).value

      expect(Array(result)).to eq(['raw failure'])
    end

    it "does not allow to call private methods on the result accidently" do
      result = transaction.call(input).value

      expect { result.print('') }.to raise_error(NoMethodError)
    end
  end

  context "non-confirming raw step result" do
    let(:input) { {"name" => "Jane", "email" => "jane@doe.com"} }

    before do
      Test::Container[:verify] = -> input { "failure" }
    end

    it "raises an exception" do
      expect { transaction.call(input) }.to raise_error(ArgumentError)
    end
  end
end
