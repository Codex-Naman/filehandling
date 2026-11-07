#include <gtest/gtest.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

class MycpTest : public ::testing::Test {
protected:
    fs::path root;

    void SetUp() override {
        char pattern[] = "/tmp/mycp-gtest-XXXXXX";
        char *directory = mkdtemp(pattern);
        ASSERT_NE(directory, nullptr);
        root = directory;
    }

    void TearDown() override {
        std::error_code error;
        fs::remove_all(root, error);
    }

    int run(const std::string &arguments) const {
        const char *configured = std::getenv("MYCP");
        const std::string executable = (configured != nullptr) ? configured : "build/mycp";
        return std::system((executable + " " + arguments).c_str());
    }

    static std::string read_file(const fs::path &path) {
        std::ifstream input(path, std::ios::binary);
        return std::string((std::istreambuf_iterator<char>(input)), {});
    }
};

TEST_F(MycpTest, CopiesAndVerifiesBinaryData) {
    const fs::path source = root / "source.bin";
    const fs::path destination = root / "destination.bin";
    std::ofstream output(source, std::ios::binary);
    output << "binary data";
    output.close();

    ASSERT_EQ(run("--buffer 512 --verify " + source.string() + " " + destination.string()), 0);
    EXPECT_EQ(read_file(source), read_file(destination));
}

TEST_F(MycpTest, CopiesNestedDirectories) {
    const fs::path source = root / "source";
    const fs::path destination = root / "destination";
    fs::create_directories(source / "nested" / "deeper");
    std::ofstream(source / "root.txt") << "root";
    std::ofstream(source / "nested" / "deeper" / "file.txt") << "deep";

    ASSERT_EQ(run("-r --buffer 512 --verify " + source.string() + " " + destination.string()), 0);
    EXPECT_EQ(read_file(source / "root.txt"), read_file(destination / "root.txt"));
    EXPECT_EQ(read_file(source / "nested" / "deeper" / "file.txt"),
              read_file(destination / "nested" / "deeper" / "file.txt"));
}

TEST_F(MycpTest, ResumesAValidPartialFile) {
    const fs::path source = root / "source.txt";
    const fs::path destination = root / "partial.txt";
    std::ofstream(source) << "resume this file";
    std::ofstream(destination) << "resume ";

    ASSERT_EQ(run("--buffer 512 --resume --verify " + source.string() + " " + destination.string()), 0);
    EXPECT_EQ(read_file(source), read_file(destination));
}
